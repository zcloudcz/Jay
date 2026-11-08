import 'dart:convert';

import 'package:calltype_core/messaging/contact_sync.dart';
import 'package:test/test.dart';

const _bob = 'b0000000-0000-4000-8000-000000000001';

SyncedContact _contact(
  String deviceId, {
  String handle = 'CT-BOB0-0001',
  String? name = 'Bob',
  int at = 1762590000123,
}) => SyncedContact(
  deviceId: deviceId,
  userHandle: handle,
  displayName: name,
  isBot: false,
  addedAt: DateTime.utc(2026, 10, 1, 8),
  nameChangedAt: at,
);

String _guid(int i) =>
    'c0000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}';

void main() {
  group('contact-sync body', () {
    test('upsert round-trips with the exact wire keys', () {
      final body = ContactSyncPayload.upsert([_contact(_bob)]).encode();
      expect(jsonDecode(body), {
        'op': 'upsert',
        'contacts': [
          {
            'deviceId': _bob,
            'userHandle': 'CT-BOB0-0001',
            'displayName': 'Bob',
            'isBot': false,
            'addedAt': '2026-10-01T08:00:00.000Z',
            'nameChangedAt': 1762590000123,
          },
        ],
      });
      final decoded = ContactSyncPayload.decode(body)!;
      expect(decoded.op, ContactSyncOp.upsert);
      expect(decoded.contacts.single.displayName, 'Bob');
      expect(decoded.contacts.single.nameChangedAt, 1762590000123);
    });

    test('a cleared name is null, a blank one is cleared too', () {
      final cleared = ContactSyncPayload.decode(
        ContactSyncPayload.upsert([_contact(_bob, name: '   ')]).encode(),
      )!;
      expect(cleared.contacts.single.displayName, isNull);
      expect(_contact(_bob, name: '  Mom  ').displayName, 'Mom');
    });

    test('snapshot carries contacts and conversation headers', () {
      final body = ContactSyncPayload.snapshot(
        [_contact(_bob)],
        [
          const SyncedConversation(id: 'g1', type: 'group', title: 'Team'),
          const SyncedConversation(
            id: _bob,
            type: 'direct',
            organizationId: 'org',
            organizationName: 'Acme',
          ),
        ],
      ).encode();
      final decoded = ContactSyncPayload.decode(body)!;
      expect(decoded.op, ContactSyncOp.snapshot);
      expect(decoded.contacts, hasLength(1));
      expect(decoded.conversations.map((c) => c.title), ['Team', null]);
      expect(decoded.conversations.last.organizationName, 'Acme');
    });

    test('remove carries ids and the time', () {
      final decoded = ContactSyncPayload.decode(
        ContactSyncPayload.remove([_bob], 42).encode(),
      )!;
      expect(decoded.op, ContactSyncOp.remove);
      expect(decoded.removedDeviceIds, [_bob]);
      expect(decoded.changedAt, 42);
    });

    test('invalid entries are skipped, the rest is applied', () {
      final body = jsonEncode({
        'op': 'upsert',
        'contacts': [
          _contact(_bob).toJson(),
          {..._contact(_guid(1)).toJson(), 'deviceId': 'not-a-guid'},
          {..._contact(_guid(2)).toJson(), 'userHandle': 'bob'},
          {..._contact(_guid(3)).toJson(), 'displayName': 'x' * 101},
          {..._contact(_guid(4)).toJson(), 'nameChangedAt': '1'},
          {..._contact(_guid(5)).toJson(), 'isBot': null},
          {..._contact(_guid(6)).toJson(), 'addedAt': 'yesterday'},
          'garbage',
          {..._contact(_guid(7)).toJson(), 'displayName': 'x' * 100},
        ],
      });
      final decoded = ContactSyncPayload.decode(body)!;
      expect(decoded.contacts.map((c) => c.deviceId), [_bob, _guid(7)]);
      final conversations = ContactSyncPayload.decode(
        jsonEncode({
          'op': 'snapshot',
          'contacts': [],
          'conversations': [
            {'id': 'g1', 'type': 'group'},
            {'id': 'g2', 'type': 'channel'},
            {'id': '', 'type': 'group'},
            {'id': 'g3', 'type': 'group', 'title': 7},
          ],
        }),
      )!;
      expect(conversations.conversations.map((c) => c.id), ['g1']);
    });

    test('an invalid message decodes to null', () {
      for (final body in <Object?>[
        null,
        7,
        'not json',
        '[]',
        '{}',
        '{"op":"merge","contacts":[]}',
        '{"op":"upsert"}',
        '{"op":"upsert","contacts":{}}',
        '{"op":"remove","deviceIds":[]}',
        '{"op":"remove","deviceIds":[],"changedAt":-1}',
      ]) {
        expect(ContactSyncPayload.decode(body), isNull, reason: '$body');
      }
    });

    test('more than 2000 entries is refused on both sides', () {
      final many = [for (var i = 0; i <= 2000; i++) _contact(_guid(i))];
      expect(
        () => ContactSyncPayload.upsert(many).encode(),
        throwsArgumentError,
      );
      final body = jsonEncode({
        'op': 'upsert',
        'contacts': [for (final c in many) c.toJson()],
      });
      expect(ContactSyncPayload.decode(body), isNull);
      final exactly = jsonEncode({
        'op': 'upsert',
        'contacts': [for (final c in many.take(2000)) c.toJson()],
      });
      expect(ContactSyncPayload.decode(exactly)!.contacts, hasLength(2000));
    });

    test('a large snapshot is split into parts within the limits', () {
      final contacts = [for (var i = 0; i < 4500; i++) _contact(_guid(i))];
      final conversations = [
        for (var i = 0; i < 2100; i++)
          SyncedConversation(id: 'g$i', type: 'group'),
      ];
      final parts = ContactSyncPayload.snapshots(contacts, conversations);
      expect(parts.map((p) => p.contacts.length), [2000, 2000, 500]);
      expect(parts.map((p) => p.conversations.length), [2000, 100, 0]);
      final decoded = [
        for (final p in parts) ContactSyncPayload.decode(p.encode())!,
      ];
      expect(
        decoded.expand((p) => p.contacts).map((c) => c.deviceId).toSet(),
        hasLength(4500),
      );
      expect(ContactSyncPayload.snapshots(const [], const []), hasLength(1));
    });
  });

  group('last writer wins', () {
    test('the newer name wins in either arrival order', () {
      expect(
        remoteNameWins(
          localAt: 1,
          localName: 'A',
          remoteAt: 2,
          remoteName: 'B',
        ),
        isTrue,
      );
      expect(
        remoteNameWins(
          localAt: 2,
          localName: 'B',
          remoteAt: 1,
          remoteName: 'A',
        ),
        isFalse,
      );
    });

    test('a tie ends with the same name everywhere', () {
      bool wins(String? local, String? remote) => remoteNameWins(
        localAt: 5,
        localName: local,
        remoteAt: 5,
        remoteName: remote,
      );
      expect(wins('Anna', 'Bob'), isTrue);
      expect(wins('Bob', 'Anna'), isFalse);
      expect(wins(null, 'Bob'), isTrue);
      expect(wins('Bob', null), isFalse);
      expect(wins('Bob', 'Bob'), isFalse);
    });
  });
}
