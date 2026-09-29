import 'dart:convert';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:jay_archiver/jay_archiver.dart';
import 'package:test/test.dart';

import 'helpers.dart';

class _MemoryStore extends SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

void main() {
  late FakeHub hub;
  late SignalRClient signalR;
  late SessionManager archiverSessions;
  late KeyManager archiverKeys;
  late FakeUser alice;
  late SignalGroupMessageSource source;
  final logs = <String>[];

  setUp(() async {
    hub = FakeHub();
    final db = AppDatabase(NativeDatabase.memory());
    archiverKeys = KeyManager(secureStorage: _MemoryStore());
    archiverSessions = SessionManager(database: db, keyManager: archiverKeys);
    signalR = SignalRClient(
      baseUrl: 'http://unused',
      deviceId: 'archiver',
      transportFactory: (_, _) => hub,
    );
    await signalR.connect();
    alice = await FakeUser.create('alice');
    logs.clear();
    source = SignalGroupMessageSource(
      signalR: signalR,
      sessions: archiverSessions,
      log: logs.add,
    );
  });

  tearDown(() async {
    signalR.close();
    await alice.close();
  });

  test('decrypts a text group message into archivable metadata', () async {
    const body = 'the secret plaintext marker';
    final data = await alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      body,
      groupId: 'g1',
    );

    final events = source.messages;
    final first = events.first;
    hub.deliver(data);
    final event = await first;

    expect(event.groupId, 'g1');
    expect(event.senderId, 'alice');
    expect(event.kind, 'text');
    expect(event.sizeBytes, utf8.encode(body).length);
    expect(event.contentHashHex, crypto.sha256.convert(utf8.encode(body)).toString());
  });

  test('1:1 (non-group) messages are dropped: acked, never decrypted or emitted', () async {
    final data = await alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      'hi',
      groupId: 'g1',
    )
      ..['groupId'] = null; // simulate a direct message

    var sawEvent = false;
    final sub = source.messages.listen((_) => sawEvent = true);
    hub.deliver(data);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(sawEvent, isFalse);
    // Acked so the server stops redelivering it — anyone can address a direct
    // message to the auditor's device id.
    expect(hub.calls('AcknowledgeMessage'), hasLength(1));
  });

  test('undecryptable messages are logged by id only, never emitted', () async {
    final garbage = {
      'senderId': 'alice',
      'messageId': 'bad-1',
      'groupId': 'g1',
      'encryptedBody': 'not-valid-base64-envelope!!',
    };

    var sawEvent = false;
    final sub = source.messages.listen((_) => sawEvent = true);
    hub.deliver(garbage);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(sawEvent, isFalse);
    expect(logs, hasLength(1));
    expect(logs.single, contains('bad-1'));
  });

  test('attachment sizeBytes reflects the decoded file, not the JSON envelope', () async {
    final fileBytes = List<int>.generate(1000, (i) => i % 256);
    final envelope = jsonEncode({'name': 'a.bin', 'data': base64Encode(fileBytes)});
    final data = await alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      envelope,
      groupId: 'g1',
      type: 'file',
    );

    final first = source.messages.first;
    hub.deliver(data);
    final event = await first;

    expect(event.kind, 'attachment');
    expect(event.sizeBytes, fileBytes.length);
    expect(event.contentHashHex, crypto.sha256.convert(utf8.encode(envelope)).toString());
  });

  group('call-event (H1)', () {
    Map<String, dynamic> callEventBody({
      String callId = 'c1',
      String role = 'caller',
      String peerDeviceId = 'bob',
      String startedAt = '2026-09-18T12:00:00.000Z',
      String? endedAt = '2026-09-18T12:05:00.000Z',
      String media = 'audio',
      String outcome = 'completed',
    }) => {
      'callId': callId,
      'role': role,
      'peerDeviceId': peerDeviceId,
      'startedAt': startedAt,
      'endedAt': endedAt,
      'media': media,
      'outcome': outcome,
    };

    Future<Map<String, dynamic>> deliverCallEvent(Map<String, dynamic> details) async => alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      jsonEncode(details),
      groupId: 'g1',
      type: 'call-event',
    );

    test('valid call-event is archived as call-metadata with matching hash/size', () async {
      final body = jsonEncode(callEventBody());
      final data = await deliverCallEvent(callEventBody());

      final first = source.messages.first;
      hub.deliver(data);
      final event = await first;

      expect(event.kind, 'call-metadata');
      expect(event.detailsJson, body);
      expect(event.sizeBytes, utf8.encode(body).length);
      expect(event.contentHashHex, crypto.sha256.convert(utf8.encode(body)).toString());
    });

    test('unknown key is rejected, not emitted', () async {
      final details = callEventBody()..['extra'] = 'nope';
      final data = await deliverCallEvent(details);

      var sawEvent = false;
      final sub = source.messages.listen((_) => sawEvent = true);
      hub.deliver(data);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(sawEvent, isFalse);
    });

    test('missing key is rejected, not emitted', () async {
      final details = callEventBody()..remove('outcome');
      final data = await deliverCallEvent(details);

      var sawEvent = false;
      final sub = source.messages.listen((_) => sawEvent = true);
      hub.deliver(data);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(sawEvent, isFalse);
    });

    test('invalid enum value is rejected, not emitted', () async {
      final data = await deliverCallEvent(callEventBody(outcome: 'bogus'));

      var sawEvent = false;
      final sub = source.messages.listen((_) => sawEvent = true);
      hub.deliver(data);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(sawEvent, isFalse);
    });

    test('unparseable timestamp is rejected, not emitted', () async {
      final data = await deliverCallEvent(callEventBody(startedAt: 'not-a-date'));

      var sawEvent = false;
      final sub = source.messages.listen((_) => sawEvent = true);
      hub.deliver(data);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(sawEvent, isFalse);
    });

    test('endedAt before startedAt is rejected, not emitted', () async {
      final data = await deliverCallEvent(callEventBody(
        startedAt: '2026-09-18T12:05:00.000Z',
        endedAt: '2026-09-18T12:00:00.000Z',
      ));

      var sawEvent = false;
      final sub = source.messages.listen((_) => sawEvent = true);
      hub.deliver(data);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(sawEvent, isFalse);
    });

    test('null endedAt (call still in progress / never answered) is valid', () async {
      final body = jsonEncode(callEventBody(endedAt: null));
      final data = await deliverCallEvent(callEventBody(endedAt: null));

      final first = source.messages.first;
      hub.deliver(data);
      final event = await first;

      expect(event.kind, 'call-metadata');
      expect(event.detailsJson, body);
    });
  });
  // Contracts §3 table (X0): what the auditor does with every wire type.
  group('newer message types (contracts §3, K2)', () {
    const ref = '5c0b8a4e-1f7d-4c52-9b1e-0f3a2d6c7e81';
    String sha(String s) => crypto.sha256.convert(utf8.encode(s)).toString();

    Future<Map<String, dynamic>> send(
      String type, {
      String body = '',
      Map<String, Object?> extra = const {},
    }) async => alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      body,
      groupId: 'g1',
      type: type,
      extra: extra,
    );

    /// Delivers and returns (emitted events, acks).
    Future<(List<IncomingGroupMessage>, int)> run(
      Map<String, dynamic> data,
    ) async {
      final events = <IncomingGroupMessage>[];
      final sub = source.messages.listen(events.add);
      hub.deliver(data);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      return (events, hub.calls('AcknowledgeMessage').length);
    }

    String mediaBody() => jsonEncode({
      'v': 1,
      'kind': 'image',
      'blobId': ref,
      'key': base64Encode(List.filled(32, 1)),
      'sha256': 'b' * 64,
      'size': 183422,
      'mime': 'image/jpeg',
    });

    test(
      'media → attachment with the REFERENCED size, blob not fetched',
      () async {
        final body = mediaBody();
        final (events, acks) = await run(await send('media', body: body));
        expect(events.single.kind, 'attachment');
        expect(events.single.sizeBytes, 183422);
        expect(events.single.contentHashHex, sha(body));
        expect(events.single.detailsJson, isNull);
        expect(acks, 0, reason: 'the Archiver acks after the write');
      },
    );

    test(
      'malformed media is not emitted and not acked (content rule)',
      () async {
        final (events, acks) = await run(
          await send('media', body: '{"v":1,"kind":"image"}'),
        );
        expect(events, isEmpty);
        expect(acks, 0);
        expect(logs.single, isNot(contains('image')));
      },
    );

    test('unknown content type → other with {"type"} details', () async {
      const body = 'whatever a newer client sends';
      final (events, _) = await run(await send('poll', body: body));
      final event = events.single;
      expect(event.kind, 'other');
      expect(event.detailsJson, '{"type":"poll"}');
      expect(event.contentHashHex, sha('{"type":"poll"}'));
      expect(event.sizeBytes, utf8.encode(body).length);
    });

    test('an over-long unknown type is cut to 32 UTF-16 units', () async {
      final longType = '${'x' * 31}😀tail';
      final (events, _) = await run(await send(longType));
      expect(events.single.detailsJson, jsonEncode({'type': 'x' * 31}));
    });

    test(
      'other details: control chars stripped, escaping kept ≤ 64 chars',
      () async {
        final (events, _) = await run(await send('a\u0001b\n"${'"' * 40}'));
        final details = events.single.detailsJson!;
        expect(details.length, lessThanOrEqualTo(64));
        final type = (jsonDecode(details) as Map)['type'] as String;
        expect(type, startsWith('ab"'));
        expect(type.length, lessThanOrEqualTo(32));
        expect(events.single.contentHashHex, sha(details));
      },
    );

    test('edit ref is serialised in canonical lowercase form', () async {
      final (events, _) = await run(
        await send(
          'edit',
          body: 'x',
          extra: {'ctl': true, 'ref': ref.toUpperCase()},
        ),
      );
      expect(events.single.detailsJson, startsWith('{"ref":"$ref",'));
    });

    for (final type in [
      'receipt',
      'profile',
      'device-list',
      'sync',
      'future-control',
    ]) {
      test('$type (control) → acked WITHOUT a record', () async {
        final (events, acks) = await run(
          await send(
            type,
            extra: {
              'ctl': true,
              'kind': 'read',
              'ref': [ref],
            },
          ),
        );
        expect(events, isEmpty);
        expect(acks, 1);
      });
    }

    test('receipt without ctl is still control', () async {
      final (events, acks) = await run(
        await send(
          'receipt',
          extra: {
            'kind': 'read',
            'ref': [ref],
          },
        ),
      );
      expect(events, isEmpty);
      expect(acks, 1);
    });

    test('group-update → group-event, no details', () async {
      const body = '{"op":"add","groupId":"g1","members":["x"]}';
      final (events, _) = await run(
        await send('group-update', body: body, extra: {'ctl': true}),
      );
      expect(events.single.kind, 'group-event');
      expect(events.single.detailsJson, isNull);
      expect(events.single.contentHashHex, sha(body));
    });

    test('edit → details {ref, bodyHash of the new text}', () async {
      final (events, _) = await run(
        await send(
          'edit',
          body: 'fixed text',
          extra: {'ctl': true, 'ref': ref},
        ),
      );
      final details = '{"ref":"$ref","bodyHash":"${sha('fixed text')}"}';
      expect(events.single.kind, 'edit');
      expect(events.single.detailsJson, details);
      expect(events.single.contentHashHex, sha(details));
      expect(events.single.sizeBytes, 'fixed text'.length);
    });

    test('reaction → details with the emoji hash', () async {
      final (events, _) = await run(
        await send('reaction', extra: {'ctl': true, 'ref': ref, 'emoji': '👍'}),
      );
      expect(
        events.single.detailsJson,
        '{"ref":"$ref","bodyHash":"${sha('👍')}"}',
      );
      expect(events.single.sizeBytes, utf8.encode('👍').length);
    });

    test('delete → details with a null bodyHash, size 0', () async {
      final (events, _) = await run(
        await send('delete', extra: {'ctl': true, 'ref': ref}),
      );
      expect(events.single.kind, 'delete');
      expect(events.single.detailsJson, '{"ref":"$ref","bodyHash":null}');
      expect(events.single.sizeBytes, 0);
    });

    test('malformed edit (ref not a UUID) → acked without a record', () async {
      final (events, acks) = await run(
        await send('edit', body: 'x', extra: {'ctl': true, 'ref': 'nope'}),
      );
      expect(events, isEmpty);
      expect(acks, 1);
    });
  });
}
