import 'dart:math' as math;

import 'package:calltype/app/theme.dart';
import 'package:calltype/features/chat/participant_colors.dart';
import 'package:calltype/l10n/l10n.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Spec 2026-11-09-participant-colors: hash (D4), person key (D3), palette
/// contrast (D5) and the local store (D6).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('hash', () {
    test('FNV-1a 32 bit matches the reference values', () {
      // Reference: offset basis for the empty string, the rest computed with
      // an independent implementation (Python, arbitrary precision ints).
      expect(fnv1a32(''), 0x811C9DC5);
      expect(fnv1a32('CT-77NN-3FMS'), 0xD34B43A7);
      expect(fnv1a32('CT-BOB0-0001'), 0x8C6D2C28);
      expect(fnv1a32('b0000000-0000-4000-8000-000000000001'), 0xFBBC691C);
      // UTF-8, not UTF-16 code units.
      expect(fnv1a32('Žluťoučký'), 0x1DA9B4F6);
    });

    test('the default index is stable (palette order is a contract)', () {
      expect(defaultParticipantColorIndex('CT-77NN-3FMS'), 5);
      expect(defaultParticipantColorIndex('CT-96NG-BRG4'), 5);
      expect(defaultParticipantColorIndex('CT-BOB0-0001'), 8);
      expect(
        defaultParticipantColorIndex('b0000000-0000-4000-8000-000000000001'),
        2,
      );
      expect(participantPalette.map((c) => c.id), [
        'red',
        'orange',
        'amber',
        'green',
        'teal',
        'cyan',
        'blue',
        'indigo',
        'purple',
        'pink',
      ]);
    });
  });

  group('person key', () {
    final contact = Contact(
      deviceId: 'b0000000-0000-4000-8000-000000000002',
      userHandle: 'ct-carl-0002',
      identityKey: Uint8List(0),
      verified: false,
      addedAt: DateTime(2026),
      isBot: false,
      nameChangedAt: 0,
    );

    test('the member list handle wins, upper case', () {
      expect(
        participantKey(
          'B0000000-0000-4000-8000-000000000001',
          members: const [
            GroupMemberInfo(
              deviceId: 'b0000000-0000-4000-8000-000000000001',
              userHandle: 'ct-bob0-0001',
            ),
          ],
        ),
        'CT-BOB0-0001',
      );
    });

    test('the contact handle when the member list has none', () {
      expect(
        participantKey(
          'b0000000-0000-4000-8000-000000000002',
          members: const [
            GroupMemberInfo(deviceId: 'b0000000-0000-4000-8000-000000000002'),
          ],
          contacts: [contact],
        ),
        'CT-CARL-0002',
      );
    });

    test('else the sender id, lower case', () {
      expect(
        participantKey('B0000000-0000-4000-8000-00000000000F'),
        'b0000000-0000-4000-8000-00000000000f',
      );
    });

    test('stored keys normalize the same way', () {
      expect(normalizeParticipantKey(' ct-bob0-0001 '), 'CT-BOB0-0001');
      expect(normalizeParticipantKey('ABC'), 'abc');
      expect(normalizeParticipantKey('  '), isNull);
    });
  });

  group('palette contrast (WCAG 2.2 1.4.3 / 1.4.11)', () {
    double ratio(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    for (final (name, theme) in [
      ('light', AppTheme.light),
      ('dark', AppTheme.dark),
    ]) {
      test('$name: label >= 4.5:1 on bubble, page and own bubble', () {
        final scheme = theme.colorScheme;
        for (final entry in participantPalette) {
          final color = entry.forBrightness(theme.brightness);
          // Bubble and page: the label and the outline (3:1 is implied).
          // Own bubble: a quote of this person inside my reply (D8).
          for (final background in [
            scheme.surfaceContainerHighest,
            scheme.surface,
            scheme.primaryContainer,
          ]) {
            expect(
              ratio(color, background),
              greaterThanOrEqualTo(4.5),
              reason: '${entry.id} on $background',
            );
          }
        }
      });
    }
  });

  test('every palette entry has a name in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final names = {
        for (var i = 0; i < participantPalette.length; i++)
          participantColorName(l10n, i),
      };
      expect(names, hasLength(participantPalette.length), reason: '$locale');
    }
  });

  group('store', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<Map<String, String>> rows() async => {
      for (final r in await db.select(db.backupState).get()) r.key: r.value,
    };

    test('a choice is stored in backup_state and read back', () async {
      final store = ParticipantColors(database: db);
      addTearDown(store.dispose);
      var notified = 0;
      store.addListener(() => notified++);
      await store.setChoice('CT-BOB0-0001', 3);
      expect(await rows(), {'participant_color:CT-BOB0-0001': '3'});
      expect(store.indexFor('ct-bob0-0001'), 3);
      expect(notified, 1);

      final again = ParticipantColors(database: db);
      addTearDown(again.dispose);
      await again.load();
      expect(again.chosenIndex('CT-BOB0-0001'), 3);
      expect(
        again.colorFor('CT-BOB0-0001', Brightness.dark),
        participantPalette[3].dark,
      );
    });

    test('"Automatic" deletes the key and falls back to the hash', () async {
      final store = ParticipantColors(database: db);
      addTearDown(store.dispose);
      await store.setChoice('CT-BOB0-0001', 0);
      await store.setChoice('CT-BOB0-0001', null);
      expect(await rows(), isEmpty);
      expect(store.chosenIndex('CT-BOB0-0001'), isNull);
      expect(store.indexFor('CT-BOB0-0001'), 8);
    });

    test('bad stored rows are ignored, not fatal', () async {
      await db.batch(
        (b) => b.insertAll(db.backupState, [
          BackupStateCompanion.insert(
            key: 'participant_color:CT-AAAA-0001',
            value: '99',
          ),
          BackupStateCompanion.insert(
            key: 'participant_color:CT-AAAA-0002',
            value: 'x',
          ),
          BackupStateCompanion.insert(
            key: 'participant_color:CT-AAAA-0003',
            value: '9',
          ),
          BackupStateCompanion.insert(key: 'bot_notice_seen:x', value: '1'),
        ]),
      );
      final store = ParticipantColors(database: db);
      addTearDown(store.dispose);
      await store.load();
      expect(store.chosenIndex('CT-AAAA-0001'), isNull);
      expect(store.chosenIndex('CT-AAAA-0002'), isNull);
      expect(store.chosenIndex('CT-AAAA-0003'), 9);
    });

    test('an out-of-range choice is refused', () async {
      final store = ParticipantColors(database: db);
      addTearDown(store.dispose);
      expect(() => store.setChoice('CT-A', 10), throwsRangeError);
    });

    test('start() follows rows written by someone else (restore)', () async {
      final store = ParticipantColors(database: db)..start();
      addTearDown(store.dispose);
      await db
          .into(db.backupState)
          .insert(
            BackupStateCompanion.insert(
              key: 'participant_color:CT-BOB0-0001',
              value: '6',
            ),
          );
      for (
        var i = 0;
        i < 50 && store.chosenIndex('CT-BOB0-0001') == null;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(store.chosenIndex('CT-BOB0-0001'), 6);
    });

    test('without a database choices live in memory', () async {
      final store = ParticipantColors();
      addTearDown(store.dispose);
      await store.setChoice('CT-BOB0-0001', 1);
      expect(store.indexFor('CT-BOB0-0001'), 1);
    });
  });
}
