import 'package:calltype_protocol/messaging/agent_payload.dart';
import 'package:test/test.dart';

void main() {
  // Every parser gets the same garbage: none of it may throw.
  final garbage = <Object?>[
    null,
    1,
    'x',
    true,
    {'a': 1},
    [null, 1, [], {}],
    <Object?>[
      {'id': null, 'label': null},
    ],
  ];

  test('no parser throws on garbage', () {
    for (final raw in garbage) {
      expect(() => parseMentions(raw), returnsNormally);
      expect(() => parseActions(raw), returnsNormally);
      expect(() => parseActionRef(raw), returnsNormally);
      expect(() => parseEditOf(raw), returnsNormally);
    }
  });

  group('parseMentions', () {
    test('lower-cases, trims, dedupes and skips non-strings', () {
      expect(parseMentions(['AB-CD', 'ab-cd', 1, null, ' Ef ', '', '  ']), [
        'ab-cd',
        'ef',
      ]);
    });

    test('keeps at most 50', () {
      final raw = [for (var i = 0; i < 80; i++) 'id-$i'];
      final parsed = parseMentions(raw);
      expect(parsed, hasLength(maxMentions));
      expect(parsed.last, 'id-49');
    });

    test('non-list is empty', () {
      expect(parseMentions('a,b'), isEmpty);
      expect(parseMentions({'a': 'b'}), isEmpty);
    });
  });

  group('parseActions', () {
    test('drops invalid entries, keeps valid ones in order', () {
      final parsed = parseActions([
        {'id': 'approve:run_1:req-2:once', 'label': 'Approve once'},
        {'id': 'bad id', 'label': 'space in id'},
        {'id': 'x' * 65, 'label': 'id too long'},
        {'id': 'ok', 'label': 'l' * 41},
        {'id': 'blank', 'label': '   '},
        {'id': 'num', 'label': 5},
        'not a map',
        {'id': 'deny', 'label': 'Deny'},
        {'id': 'deny', 'label': 'duplicate id'},
      ]);
      expect(parsed, [
        const MessageButton(
          id: 'approve:run_1:req-2:once',
          label: 'Approve once',
        ),
        const MessageButton(id: 'deny', label: 'Deny'),
      ]);
    });

    test('limits: id 64, label 40 characters (runes), max 8', () {
      expect(
        parseActions([
          {'id': 'x' * 64, 'label': 'l' * 40},
        ]),
        hasLength(1),
      );
      // 40 emoji are 80 UTF-16 units but 40 characters: still valid.
      expect(
        parseActions([
          {'id': 'e', 'label': '\u{1F44D}' * 40},
        ]),
        hasLength(1),
      );
      final many = [
        for (var i = 0; i < 12; i++) {'id': 'b$i', 'label': 'B$i'},
      ];
      expect(parseActions(many).map((b) => b.id), [
        for (var i = 0; i < 8; i++) 'b$i',
      ]);
    });

    test('toJson round trip and the column helpers', () {
      const buttons = [
        MessageButton(id: 'a', label: 'Say "hi"'),
        MessageButton(id: 'b', label: 'B'),
      ];
      expect(parseActions([for (final b in buttons) b.toJson()]), buttons);
      expect(encodeActionsJson(const []), isNull);
      expect(decodeActionsJson(encodeActionsJson(buttons)), buttons);
      expect(decodeActionsJson('{broken'), isEmpty);
      expect(decodeActionsJson(null), isEmpty);
      expect(buttons.first.isValid, isTrue);
      expect(const MessageButton(id: 'a b', label: 'x').isValid, isFalse);
    });
  });

  group('parseActionRef', () {
    test('valid', () {
      expect(
        parseActionRef({'messageId': 'm-1', 'id': 'deny'}),
        const ActionRef(messageId: 'm-1', id: 'deny'),
      );
      expect(const ActionRef(messageId: 'm', id: 'i').toJson(), {
        'messageId': 'm',
        'id': 'i',
      });
    });

    test('invalid is null', () {
      expect(parseActionRef({'messageId': 'm-1'}), isNull);
      expect(parseActionRef({'messageId': '', 'id': 'x'}), isNull);
      expect(parseActionRef({'messageId': 'm', 'id': 'has space'}), isNull);
      expect(parseActionRef({'messageId': 3, 'id': 'x'}), isNull);
    });
  });

  test('parseEditOf', () {
    expect(parseEditOf('m-1'), 'm-1');
    expect(parseEditOf(''), isNull);
    expect(parseEditOf(7), isNull);
    expect(parseEditOf(null), isNull);
  });
}
