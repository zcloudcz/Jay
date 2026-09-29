import 'dart:async';
import 'dart:convert';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

/// Contracts §3 table, one test per row, against the REAL crypto stack:
/// every wire type an older/newer peer may send must end up acknowledged,
/// and only content may create conversations, rows or unread badges.
void main() {
  late TestDevice alice;
  late TestDevice bob;
  late StreamController<Map<String, dynamic>> transport;
  late MessageInboxService inbox;
  late List<String> acks;
  late List<Message> persisted;
  late List<ControlEvent> events;
  late List<Object> errors;
  var nextId = 0;

  MessageInboxService makeInbox() => MessageInboxService(
    database: bob.db,
    sessionManager: bob.sessions,
    incomingMessages: transport.stream,
    myDeviceId: () => bob.id,
    acknowledge: (sender, id) async => acks.add(id),
  );

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
    transport = StreamController<Map<String, dynamic>>();
    acks = [];
    persisted = [];
    events = [];
    errors = [];
    inbox = makeInbox();
    inbox.persistedMessages.listen(persisted.add);
    inbox.controlEvents.listen(events.add);
    inbox.errors.listen(errors.add);
    await alice.sessions.initiateSession(bob.id, await bob.keyBundle());
  });
  tearDown(() async {
    await inbox.dispose();
    await transport.close();
    await alice.close();
    await bob.close();
  });

  /// Encrypts [fields] (merged over a valid v1 envelope) from Alice to Bob.
  Future<Map<String, dynamic>> delivery(
    String type, {
    String body = '',
    String? groupId,
    Map<String, Object?> fields = const {},
  }) async {
    final id = 'message-${nextId++}';
    final envelope = await alice.sessions.encryptMessage(
      bob.id,
      jsonEncode({
        'v': 1,
        'id': id,
        'type': type,
        'body': body,
        'groupId': groupId,
        'groupName': null,
        'createdAt': '2026-09-29T10:00:00.000Z',
        ...fields,
      }),
    );
    return {
      'messageId': id,
      'senderId': alice.id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': groupId,
      'createdAt': '2026-09-29T10:00:01.000Z',
    };
  }

  Future<void> deliver(Map<String, dynamic> data) async {
    transport.add(data);
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> start() async => inbox.start();

  Future<bool> logged(String id) async =>
      await (bob.db.select(
        bob.db.inboundLog,
      )..where((l) => l.messageId.equals(id))).getSingleOrNull() !=
      null;

  group('control messages (ctl) never create rows or badges', () {
    for (final type in [
      'receipt',
      'reaction',
      'edit',
      'delete',
      'profile',
      'device-list',
      'device-list-request',
      'sync',
      'provision',
      'some-future-control',
    ]) {
      test(type, () async {
        await start();
        final data = await delivery(
          type,
          fields: {'ctl': true, 'ref': 'x', 'kind': 'read'},
        );
        await deliver(data);
        expect(acks, [data['messageId']]);
        expect(await logged(data['messageId'] as String), isTrue);
        expect(await bob.db.select(bob.db.messages).get(), isEmpty);
        expect(await bob.db.select(bob.db.conversations).get(), isEmpty);
        expect(persisted, isEmpty);
      });
    }

    test('a known control type is control even without ctl', () async {
      await start();
      final data = await delivery(
        'receipt',
        fields: {
          'ref': ['m'],
        },
      );
      await deliver(data);
      expect(acks, [data['messageId']]);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
    });

    test('group-update in a group: no conversation, no badge, ack', () async {
      await start();
      await bob.db
          .into(bob.db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'g1',
              type: 'group',
              unreadCount: const Value(2),
            ),
          );
      final data = await delivery(
        'group-update',
        groupId: 'g1',
        body: '{"op":"rename","groupId":"g1","name":"x"}',
        fields: {'ctl': true},
      );
      await deliver(data);
      expect(acks, [data['messageId']]);
      final conversation = await bob.db
          .select(bob.db.conversations)
          .getSingle();
      expect(conversation.unreadCount, 2);
      expect(conversation.lastMessageAt, isNull);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
    });
  });

  group('content', () {
    test('media is stored verbatim, counts as unread and is emitted', () async {
      await start();
      const body = '{"v":1,"kind":"image","blobId":"b"}';
      final data = await delivery('media', body: body);
      await deliver(data);
      final row = await bob.db.select(bob.db.messages).getSingle();
      expect(row.type, 'media');
      expect(row.body, body);
      expect(row.conversationId, alice.id);
      expect(
        (await bob.db.select(bob.db.conversations).getSingle()).unreadCount,
        1,
      );
      expect(persisted.single.id, data['messageId']);
      expect(acks, [data['messageId']]);
    });

    test(
      'an unknown type without ctl is stored for a later version (K1)',
      () async {
        await start();
        final data = await delivery('poll', body: '{"q":"?"}');
        await deliver(data);
        final row = await bob.db.select(bob.db.messages).getSingle();
        expect(row.type, 'poll');
        expect(row.body, '{"q":"?"}');
        expect(
          (await bob.db.select(bob.db.conversations).getSingle()).unreadCount,
          1,
        );
        expect(persisted, hasLength(1));
        expect(acks, [data['messageId']]);
      },
    );

    test(
      'text with replyTo/forwarded/expiresInSec is still plain text',
      () async {
        await start();
        final data = await delivery(
          'text',
          body: 'quoted',
          fields: {
            'replyTo': {'id': 'm0', 'senderId': 'bob', 'preview': 'hi'},
            'forwarded': true,
            'expiresInSec': null,
          },
        );
        await deliver(data);
        final row = await bob.db.select(bob.db.messages).getSingle();
        expect(row.body, 'quoted');
        expect(row.type, 'text');
        expect(acks, [data['messageId']]);
      },
    );

    test('a received "system" line is dropped, never stored', () async {
      await start();
      final data = await delivery(
        'system',
        body: '{"event":"member-removed","actor":"bob"}',
      );
      await deliver(data);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
      expect(acks, [data['messageId']]);
    });

    test('a malformed file is acknowledged and dropped', () async {
      await start();
      final data = await delivery('file', body: '{"name":"../x","data":""}');
      await deliver(data);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
      expect(await bob.db.select(bob.db.conversations).get(), isEmpty);
      expect(acks, [data['messageId']]);
      expect(errors.single, isA<FormatException>());
    });

    test('a non-string type is malformed: ack and drop', () async {
      await start();
      final data = await delivery('text', fields: {'type': 7});
      await deliver(data);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
      expect(acks, [data['messageId']]);
    });
  });

  test('redelivered control message is acked from InboundLog without '
      'touching the ratchet', () async {
    await start();
    final data = await delivery('receipt', fields: {'ctl': true});
    await deliver(data);
    final before = await (bob.db.select(
      bob.db.signalSessions,
    )..where((s) => s.address.equals(alice.id))).getSingle();
    await deliver(data);
    final after = await (bob.db.select(
      bob.db.signalSessions,
    )..where((s) => s.address.equals(alice.id))).getSingle();
    expect(acks, [data['messageId'], data['messageId']]);
    expect(after.sessionData, before.sessionData);
    expect(errors, isEmpty);
  });

  group('registry', () {
    test(
      'a registered handler runs and Applied reaches controlEvents',
      () async {
        final seen = <InboundContext>[];
        inbox.registerHandler(
          'reaction',
          _Handler((ctx) async {
            seen.add(ctx);
            return Applied(
              ControlEvent(
                type: ctx.type,
                conversationId: ctx.conversationId,
                senderId: ctx.senderId,
                refs: [ctx.payload['ref'] as String],
              ),
            );
          }),
        );
        await start();
        final data = await delivery(
          'reaction',
          fields: {'ctl': true, 'ref': 'm1', 'emoji': '👍'},
        );
        await deliver(data);
        expect(seen.single.myDeviceId, bob.id);
        expect(seen.single.conversationId, alice.id);
        expect(
          seen.single.serverCreatedAt,
          DateTime.utc(2026, 9, 29, 10, 0, 1),
        );
        expect(seen.single.fromOwnDevice, isFalse);
        expect(events.single.refs, ['m1']);
        expect(persisted, isEmpty);
        expect(acks, [data['messageId']]);
      },
    );

    test('FormatException from a handler: its writes roll back, the message '
        'is logged and acknowledged', () async {
      inbox.registerHandler(
        'edit',
        _Handler((ctx) async {
          await ctx.db
              .into(ctx.db.appSettings)
              .insert(AppSettingsCompanion.insert(key: 'k', value: 'v'));
          throw const FormatException('bad edit');
        }),
      );
      await start();
      final data = await delivery('edit', fields: {'ctl': true});
      await deliver(data);
      expect(await bob.db.select(bob.db.appSettings).get(), isEmpty);
      expect(await logged(data['messageId'] as String), isTrue);
      expect(acks, [data['messageId']]);
    });

    test(
      'any other exception: nothing commits, no ack, redelivery works',
      () async {
        var fail = true;
        inbox.registerHandler(
          'edit',
          _Handler((ctx) async {
            if (fail) throw StateError('database busy');
            return const Ignored();
          }),
        );
        await start();
        final data = await delivery('edit', fields: {'ctl': true});
        await deliver(data);
        expect(acks, isEmpty);
        expect(await logged(data['messageId'] as String), isFalse);
        fail = false;
        await deliver(data); // the ratchet was rolled back: decrypts again
        expect(acks, [data['messageId']]);
      },
    );

    test(
      're-entrant dispatch stores synced content as my own message',
      () async {
        inbox.registerHandler(
          'sync',
          _Handler((ctx) async {
            final inner = jsonDecode(ctx.body) as Map<String, dynamic>;
            return inbox.dispatch(
              ctx.copyWith(
                payload: inner,
                fromOwnDevice: true,
                conversationId: 'carol',
              ),
            );
          }),
        );
        await start();
        final data = await delivery(
          'sync',
          fields: {'ctl': true},
          body: jsonEncode({'v': 1, 'type': 'text', 'body': 'sent elsewhere'}),
        );
        await deliver(data);
        final row = await bob.db.select(bob.db.messages).getSingle();
        expect(row.body, 'sent elsewhere');
        expect(row.conversationId, 'carol');
        expect(row.status, 'sent');
        expect(
          (await bob.db.select(bob.db.conversations).getSingle()).unreadCount,
          0,
        );
      },
    );

    test('payload observers see every valid payload', () async {
      final types = <String>[];
      inbox.addPayloadObserver((ctx) async => types.add(ctx.type));
      await start();
      await deliver(await delivery('text', body: 'a'));
      await deliver(await delivery('receipt', fields: {'ctl': true}));
      expect(types, ['text', 'receipt']);
    });
  });

  group('blocked senders', () {
    test('BlockedDevices (default hook): decrypted, acked, dropped', () async {
      await bob.db
          .into(bob.db.blockedDevices)
          .insert(
            BlockedDevicesCompanion.insert(
              deviceId: alice.id,
              blockedAt: DateTime.utc(2026),
            ),
          );
      await start();
      final first = await delivery('text', body: 'spam');
      await deliver(first);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
      expect(acks, [first['messageId']]);
      // The ratchet stayed in step: after unblocking the next one decrypts.
      await bob.db.delete(bob.db.blockedDevices).go();
      await deliver(await delivery('text', body: 'hello again'));
      expect(
        (await bob.db.select(bob.db.messages).getSingle()).body,
        'hello again',
      );
    });

    test('the hook is replaceable (G PeerDirectory)', () async {
      inbox.isBlocked = (sender) => sender == alice.id;
      await start();
      final data = await delivery('text', body: 'x');
      await deliver(data);
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
      expect(acks, [data['messageId']]);
    });
  });
}

class _Handler implements InboundTypeHandler {
  _Handler(this._handle);
  final Future<InboundResult> Function(InboundContext ctx) _handle;
  @override
  Future<InboundResult> handle(InboundContext ctx) => _handle(ctx);
}
