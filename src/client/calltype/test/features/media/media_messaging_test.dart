import 'dart:async';
import 'dart:convert';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/backup/backup_import.dart';
import 'package:calltype/features/chat/attachment_media.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/media/media_message.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype/features/media/media_store_memory.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';
import 'media_fakes.dart';

class _Api extends ApiClient {
  _Api(this.peers) : super(baseUrl: 'http://unused');
  final List<TestDevice> peers;
  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) =>
      peers.firstWhere((p) => p.id == id).keyBundle();
}

class _Transport extends SignalRClient {
  _Transport() : super(baseUrl: 'http://unused', deviceId: 'alice');
  final sent = <(String, Map<String, String>)>[];
  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => sent.add((messageId, Map.of(encryptedPayloads)));
}

/// Contract sections 3 and 4.1 end to end: ChatController.sendMedia uploads
/// through the (fake) relay and sends `type: text` + fallback + `media`;
/// the receiving inbox stores a `media` row; invalid objects fall back to
/// text; backups keep media rows.
void main() {
  late TestDevice alice;
  late TestDevice bob;
  late FakeMediaRemote remote;
  late MediaService media;
  late MemoryMediaStore store;
  late _Transport hub;
  late ChatController chat;
  late StreamController<Map<String, dynamic>> bobWire;
  late MessageInboxService bobInbox;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
    remote = FakeMediaRemote();
    store = MemoryMediaStore();
    media = MediaService(remote: remote, store: store, web: false);
    hub = _Transport();
    await alice.db
        .into(alice.db.conversations)
        .insert(ConversationsCompanion.insert(id: 'bob', type: 'direct'));
    chat = ChatController(
      database: alice.db,
      signalRClient: hub,
      sessionManager: alice.sessions,
      inbox: MessageInboxService(
        database: alice.db,
        sessionManager: alice.sessions,
        directory: () => alice.directory,
        incomingMessages: const Stream.empty(),
      ),
      apiClient: _Api([bob]),
      conversationId: 'bob',
      directory: alice.directory,
      media: media,
    );
    bobWire = StreamController<Map<String, dynamic>>();
    bobInbox = MessageInboxService(
      database: bob.db,
      sessionManager: bob.sessions,
      directory: () => bob.directory,
      incomingMessages: bobWire.stream,
      media: MediaService(
        remote: remote,
        store: MemoryMediaStore(),
        web: false,
      ),
    )..start();
    bobInbox.errors.listen((e) => printOnFailure('bob inbox: $e'));
  });

  tearDown(() async {
    chat.dispose();
    await bobInbox.dispose();
    await bobWire.close();
    hub.dispose();
    await alice.close();
    await bob.close();
  });

  Future<Message> deliverToBob(String messageId, String envelope) async {
    bobWire.add({
      'messageId': messageId,
      'senderId': alice.id,
      'encryptedBody': envelope,
    });
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
    return (bob.db.select(
      bob.db.messages,
    )..where((m) => m.id.equals(messageId))).getSingle();
  }

  PickedMedia voice(int size) => PickedMedia.bytes(
    'voice-20261107-101500.m4a',
    Uint8List.fromList(List.generate(size, (i) => i & 0xff)),
    mimeType: 'audio/mp4',
  );

  test('sendMedia uploads, sends text + fallback + media, and the receiver '
      'stores a media row', () async {
    await chat.sendMedia(
      voice(5000),
      kind: MediaKind.voice,
      durationMs: 12000,
      waveform: Uint8List.fromList(List.filled(64, 9)),
    );
    final row = await alice.db.select(alice.db.messages).getSingle();
    expect(row.type, 'media');
    expect(row.status, 'sent');
    final info = MediaInfo.tryDecode(row.body)!;
    expect(info.isDraft, isFalse);
    expect(info.expiresAt, remote.expiresAt);
    expect(remote.blobs[info.id], isNotNull);
    // The sender's own copy is local and counts as downloaded.
    expect(await store.exists(info.id, info.name), isTrue);
    expect(
      await (alice.db.select(
        alice.db.backupState,
      )..where((s) => s.key.like('mediaup:%'))).get(),
      isEmpty,
    );

    final (id, envelopes) = hub.sent.single;
    expect(id, row.id);
    final plain = jsonDecode(
      await bob.sessions.decryptMessage(
        alice.id,
        utf8.decode(base64Decode(envelopes['bob']!)),
      ),
    );
    // Old clients see a text message.
    expect(plain['type'], 'text');
    expect(plain['body'], startsWith('\u{1F3A4} Voice message (0:12)'));
    expect(plain['media']['id'], info.id);
    expect(plain['media']['kind'], 'voice');
  });

  test('inbound text + media becomes a media row; invalid media or a newer '
      'version keeps the fallback text', () async {
    await alice.sessions.initiateSession(bob.id, await bob.keyBundle());
    final good = {
      'v': 1,
      'id': '6f1c2a3b-1111-4222-8333-444455556666',
      'kind': 'video',
      'name': 'clip.mp4',
      'mime': 'video/mp4',
      'size': 10,
      'sha256': base64Encode(List.filled(32, 1)),
      'key': base64Encode(List.filled(32, 2)),
      'nonce': base64Encode(List.filled(7, 3)),
      'chunkSize': mediaChunkSize,
      'expiresAt': '2030-01-01T00:00:00Z',
    };
    Future<Message> send(String id, Object? mediaObject) async {
      final envelope = await alice.sessions.encryptMessage(
        bob.id,
        jsonEncode({
          'v': 1,
          'id': id,
          'type': 'text',
          'body': 'fallback text',
          'groupId': null,
          'media': mediaObject,
        }),
      );
      return deliverToBob(id, base64Encode(utf8.encode(envelope)));
    }

    final media = await send('m1', good);
    expect(media.type, 'media');
    expect(MediaInfo.tryDecode(media.body)!.id, good['id']);

    final broken = await send('m2', {...good, 'key': 'short'});
    expect(broken.type, 'text');
    expect(broken.body, 'fallback text');

    final newer = await send('m3', {...good, 'v': 2});
    expect(newer.type, 'text');
    expect(newer.body, 'fallback text');

    final notAMap = await send('m4', 'nonsense');
    expect(notAMap.type, 'text');
  });

  test(
    'a failed upload leaves the row failed; retry resumes and sends',
    () async {
      remote.failPutAt = 0;
      await chat.sendMedia(voice(100), kind: MediaKind.voice, durationMs: 1500);
      var row = await alice.db.select(alice.db.messages).getSingle();
      expect(row.status, 'failed');
      expect(hub.sent, isEmpty);
      // The draft already has its server id (persisted for the resume).
      expect(MediaInfo.tryDecode(row.body)!.isDraft, isFalse);
      remote.failPutAt = null;
      await chat.retryMessage(row.id);
      row = await alice.db.select(alice.db.messages).getSingle();
      expect(row.status, 'sent');
      expect(remote.created, hasLength(1), reason: 'same upload resumed');
      expect(hub.sent, hasLength(1));
    },
  );

  test('cancel: the blob is withdrawn and the row becomes failed', () async {
    final gate = Completer<void>();
    remote.putGate = gate.future;
    final sending = chat.sendMedia(voice(100), kind: MediaKind.voice);
    String? id;
    for (var i = 0; i < 50 && id == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final rows = await alice.db.select(alice.db.messages).get();
      if (rows.isNotEmpty && media.isUploading(rows.single.id)) {
        id = rows.single.id;
      }
    }
    chat.cancelMediaUpload(id!);
    gate.complete();
    await sending;
    final row = await alice.db.select(alice.db.messages).getSingle();
    expect(row.status, 'failed');
    expect(remote.deleted, hasLength(1));
    expect(hub.sent, isEmpty);
  });

  test('delete for me removes the local file unless a forward still uses '
      'it', () async {
    await chat.sendMedia(voice(100), kind: MediaKind.voice, durationMs: 1000);
    final row = await alice.db.select(alice.db.messages).getSingle();
    final info = MediaInfo.tryDecode(row.body)!;
    await chat.sendForwarded(body: row.body!, type: 'media');
    final rows = await alice.db.select(alice.db.messages).get();
    expect(rows, hasLength(2));
    expect(remote.created, hasLength(1), reason: 'forward reuses the blob');
    await chat.deleteForMe(row.id);
    expect(await store.exists(info.id, info.name), isTrue);
    await chat.deleteForMe(rows.firstWhere((r) => r.id != row.id).id);
    expect(await store.exists(info.id, info.name), isFalse);
  });

  test('backup import accepts media rows', () async {
    await importBackup(bob.db, {
      'version': 1,
      'contacts': [],
      'conversations': [
        {'id': 'alice', 'type': 'direct'},
      ],
      'messages': [
        {
          'id': 'm-media',
          'conversationId': 'alice',
          'senderId': 'alice',
          'body': '{"v":1}',
          'type': 'media',
          'status': 'delivered',
          'createdAt': '2026-11-07T10:00:00Z',
        },
      ],
    });
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.type, 'media');
  });
}
