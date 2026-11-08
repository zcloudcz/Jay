import 'dart:typed_data';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/mentions.dart';
import 'package:flutter_test/flutter_test.dart';

Contact contact(String id, String handle, {String? name, bool bot = false}) =>
    Contact(
      deviceId: id,
      userHandle: handle,
      displayName: name,
      identityKey: Uint8List(0),
      verified: false,
      addedAt: DateTime(2026),
      isBot: bot,
      nameChangedAt: 0,
    );

void main() {
  group('activeMentionQuery', () {
    test('at the start of the text', () {
      final q = activeMentionQuery('@he', 3)!;
      expect(q.start, 0);
      expect(q.query, 'he');
    });

    test('after a space, uses text up to the cursor only', () {
      final q = activeMentionQuery('hi @he there', 6)!;
      expect(q.start, 3);
      expect(q.query, 'he');
    });

    test('bare @ gives an empty query', () {
      expect(activeMentionQuery('hi @', 4)!.query, isEmpty);
    });

    test('null for mid-word @, e-mail, space after token, bad cursor', () {
      expect(activeMentionQuery('a@b', 3), isNull);
      expect(activeMentionQuery('mail me@x.cz', 12), isNull);
      expect(activeMentionQuery('@he ', 4), isNull);
      expect(activeMentionQuery('hello', 5), isNull);
      expect(activeMentionQuery('@he', -1), isNull);
      expect(activeMentionQuery('@he', 4), isNull);
    });
  });

  test('applyMention replaces only the partial token', () {
    const text = 'hi @he there';
    final q = activeMentionQuery(text, 6)!;
    final r = applyMention(text, q, 6, 'Hermes');
    expect(r.text, 'hi @Hermes  there');
    expect(r.cursor, 'hi @Hermes '.length);
  });

  test('filterMentions is case-insensitive over label, token and detail', () {
    const a = MentionCandidate(
      label: 'Boss',
      token: 'Hermes',
      detail: 'CT-AAAA-BBBB',
    );
    const b = MentionCandidate(label: 'Eve', token: 'CT-CCCC-DDDD');
    expect(filterMentions([a, b], ''), [a, b]);
    expect(filterMentions([a, b], 'HERM'), [a]);
    expect(filterMentions([a, b], 'boss'), [a]);
    expect(filterMentions([a, b], 'cccc'), [b]);
    expect(filterMentions([a, b], 'zzz'), isEmpty);
  });

  group('buildMentionCandidates', () {
    test('token is the server name, never the local rename', () {
      final c = buildMentionCandidates(
        members: const [
          GroupMemberInfo(
            deviceId: 'b',
            userHandle: 'CT-1',
            displayName: 'Hermes',
            isBot: true,
          ),
        ],
        contacts: [contact('b', 'CT-1', name: 'My buddy')],
        myIdentityId: 'me',
      );
      expect(c.single.token, 'Hermes');
      expect(c.single.label, 'My buddy');
      expect(c.single.detail, 'CT-1');
      expect(c.single.isBot, isTrue);
    });

    test('token falls back to handle; bot flag from contact', () {
      final c = buildMentionCandidates(
        members: const [GroupMemberInfo(deviceId: 'b')],
        contacts: [contact('b', 'CT-1', bot: true)],
        myIdentityId: 'me',
      );
      expect(c.single.token, 'CT-1');
      expect(c.single.label, 'CT-1');
      expect(c.single.isBot, isTrue);
    });

    test('skips self and members without any handle', () {
      final c = buildMentionCandidates(
        members: const [
          GroupMemberInfo(deviceId: 'me', userHandle: 'CT-ME'),
          GroupMemberInfo(deviceId: 'x'),
          GroupMemberInfo(deviceId: 'y', userHandle: 'CT-Y'),
        ],
        contacts: const [],
        myIdentityId: 'me',
      );
      expect(c.map((e) => e.token), ['CT-Y']);
    });
  });

  group('senderLabel', () {
    const members = [
      GroupMemberInfo(deviceId: 'a', userHandle: 'CT-A', displayName: 'Anna'),
      GroupMemberInfo(deviceId: 'h', userHandle: 'CT-H'),
    ];
    test('prefers local contact name, then profile name, then handles', () {
      final contacts = [
        contact('a', 'CT-A', name: 'Sis'),
        contact('c', 'CT-C'),
      ];
      String l(String id) =>
          senderLabel(id, members: members, contacts: contacts);
      expect(l('a'), 'Sis');
      expect(l('h'), 'CT-H');
      expect(l('c'), 'CT-C');
      expect(l('zzz'), 'zzz');
      expect(senderLabel('a', members: members, contacts: []), 'Anna');
    });
  });
}
