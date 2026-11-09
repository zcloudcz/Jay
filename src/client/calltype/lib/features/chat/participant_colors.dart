import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' show StringExpressionOperators;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';

/// Participant colors in group chats (spec 2026-11-09-participant-colors).
///
/// Every other member of a group gets a color: by default a hash of the
/// person key (D4), or the one the user picked (D6, stored locally in
/// `backup_state`). Nothing here goes over the wire (D11).

/// One palette entry: a tone for the light and one for the dark theme.
///
/// Both tones are checked by a unit test for 4.5:1 against the page and the
/// bubble background of their theme (D5).
class ParticipantColor {
  const ParticipantColor({
    required this.id,
    required this.light,
    required this.dark,
  });

  /// Stable English id, used only in code and tests.
  final String id;
  final Color light;
  final Color dark;

  Color forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// The palette. ORDER IS A CONTRACT (D5): stored choices and backups keep
/// the index, and the default hash maps to it. Append only.
const participantPalette = <ParticipantColor>[
  ParticipantColor(
    id: 'red',
    light: Color(0xFFB71C1C),
    dark: Color(0xFFFFA8A0),
  ),
  ParticipantColor(
    id: 'orange',
    light: Color(0xFFAD3A00),
    dark: Color(0xFFFFB74D),
  ),
  ParticipantColor(
    id: 'amber',
    light: Color(0xFF845600),
    dark: Color(0xFFFFD54F),
  ),
  ParticipantColor(
    id: 'green',
    light: Color(0xFF1B6E20),
    dark: Color(0xFF9AD59C),
  ),
  ParticipantColor(
    id: 'teal',
    light: Color(0xFF00695C),
    dark: Color(0xFF7FD1C8),
  ),
  ParticipantColor(
    id: 'cyan',
    light: Color(0xFF00646F),
    dark: Color(0xFF4DD0E1),
  ),
  ParticipantColor(
    id: 'blue',
    light: Color(0xFF1558B0),
    dark: Color(0xFF8AC8F8),
  ),
  ParticipantColor(
    id: 'indigo',
    light: Color(0xFF3949AB),
    dark: Color(0xFFB7BEE6),
  ),
  ParticipantColor(
    id: 'purple',
    light: Color(0xFF8E24AA),
    dark: Color(0xFFDDB0E5),
  ),
  ParticipantColor(
    id: 'pink',
    light: Color(0xFFAD1457),
    dark: Color(0xFFF8AECA),
  ),
];

/// Localized name of palette entry [index] (tooltip and screen reader label).
String participantColorName(AppLocalizations l10n, int index) =>
    switch (participantPalette[index].id) {
      'red' => l10n.participantColorRed,
      'orange' => l10n.participantColorOrange,
      'amber' => l10n.participantColorAmber,
      'green' => l10n.participantColorGreen,
      'teal' => l10n.participantColorTeal,
      'cyan' => l10n.participantColorCyan,
      'blue' => l10n.participantColorBlue,
      'indigo' => l10n.participantColorIndigo,
      'purple' => l10n.participantColorPurple,
      _ => l10n.participantColorPink,
    };

/// FNV-1a, 32 bit, over the UTF-8 bytes of [text].
///
/// WHY no plain `h * prime & 0xFFFFFFFF`: on the web an int is a double, and
/// a 32-bit value times the 25-bit prime loses the low bits above 2^53. The
/// prime is 2^24 + 0x193, so the product is split into two exact parts.
int fnv1a32(String text) {
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x193 + (hash & 0xFF) * 0x1000000) % 0x100000000;
  }
  return hash;
}

/// Default palette index of a person key (D4).
int defaultParticipantColorIndex(String personKey) =>
    fnv1a32(personKey) % participantPalette.length;

/// `backup_state` key prefix of a stored choice (D6).
const participantColorKeyPrefix = 'participant_color:';

/// The person a color belongs to (D3): the user handle in upper case when
/// the group member list or the local contact knows it, else the sender id
/// in lower case. A person with several devices keeps one key.
String participantKey(
  String senderId, {
  List<GroupMemberInfo> members = const [],
  List<Contact> contacts = const [],
}) {
  final id = senderId.toLowerCase();
  String? handle;
  for (final m in members) {
    if (m.deviceId.toLowerCase() == id && m.userHandle != null) {
      handle = m.userHandle;
    }
  }
  if (handle == null) {
    for (final c in contacts) {
      if (c.deviceId.toLowerCase() == id) handle = c.userHandle;
    }
  }
  final trimmed = handle?.trim() ?? '';
  return trimmed.isEmpty ? id : trimmed.toUpperCase();
}

/// Normalizes a key read from storage or a backup the way [participantKey]
/// writes it: a handle (`CT-...`) upper case, anything else lower case.
/// Null for an empty key.
String? normalizeParticipantKey(String key) {
  final trimmed = key.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.toUpperCase().startsWith('CT-')
      ? trimmed.toUpperCase()
      : trimmed.toLowerCase();
}

/// Choices the user made, by person key, and the colors they resolve to.
///
/// Provided app-wide so every open chat and the contacts list repaint when a
/// choice changes. Without a database (tests, previews) choices live in
/// memory only.
class ParticipantColors extends ChangeNotifier {
  ParticipantColors({AppDatabase? database}) : _db = database;

  final AppDatabase? _db;
  final Map<String, int> _chosen = {};
  StreamSubscription<List<BackupStateData>>? _watch;
  bool _disposed = false;

  /// Reads the stored choices and keeps following the table, so a backup
  /// restore or a history transfer (which write `backup_state` directly)
  /// shows up without a restart.
  void start() {
    final db = _db;
    if (db == null || _watch != null) return;
    _watch =
        (db.select(db.backupState)
              ..where((s) => s.key.like('$participantColorKeyPrefix%')))
            .watch()
            .listen(_replaceAll, onError: (Object _) {});
  }

  /// One-shot read, for callers that do not want a live subscription.
  Future<void> load() async {
    final db = _db;
    if (db == null) return;
    _replaceAll(
      await (db.select(
        db.backupState,
      )..where((s) => s.key.like('$participantColorKeyPrefix%'))).get(),
    );
  }

  void _replaceAll(List<BackupStateData> rows) {
    final next = <String, int>{};
    for (final row in rows) {
      final key = normalizeParticipantKey(
        row.key.substring(participantColorKeyPrefix.length),
      );
      final index = int.tryParse(row.value);
      if (key == null || index == null || !_validIndex(index)) continue;
      next[key] = index;
    }
    if (_sameAs(next)) return;
    _chosen
      ..clear()
      ..addAll(next);
    if (!_disposed) notifyListeners();
  }

  bool _sameAs(Map<String, int> other) =>
      other.length == _chosen.length &&
      other.entries.every((e) => _chosen[e.key] == e.value);

  static bool _validIndex(int index) =>
      index >= 0 && index < participantPalette.length;

  /// The index the user picked for [personKey], or null (automatic).
  int? chosenIndex(String personKey) =>
      _chosen[normalizeParticipantKey(personKey)];

  /// The effective palette index: the choice, else the default hash.
  int indexFor(String personKey) =>
      chosenIndex(personKey) ?? defaultParticipantColorIndex(personKey);

  Color colorFor(String personKey, Brightness brightness) =>
      participantPalette[indexFor(personKey)].forBrightness(brightness);

  /// Stores a choice; null = "Automatic" (deletes the key, D6).
  Future<void> setChoice(String personKey, int? index) async {
    final key = normalizeParticipantKey(personKey);
    if (key == null) return;
    if (index != null && !_validIndex(index)) {
      throw RangeError.index(index, participantPalette, 'index');
    }
    if (index == null) {
      _chosen.remove(key);
    } else {
      _chosen[key] = index;
    }
    if (!_disposed) notifyListeners();
    final db = _db;
    if (db == null) return;
    final storageKey = '$participantColorKeyPrefix$key';
    if (index == null) {
      await (db.delete(
        db.backupState,
      )..where((s) => s.key.equals(storageKey))).go();
    } else {
      await db
          .into(db.backupState)
          .insertOnConflictUpdate(
            BackupStateCompanion.insert(key: storageKey, value: '$index'),
          );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _watch?.cancel();
    super.dispose();
  }
}

/// The app-wide [ParticipantColors], or null where none is provided (some
/// widget tests): the chat then shows default colors without a picker.
ParticipantColors? maybeParticipantColors(
  BuildContext context, {
  bool listen = true,
}) => Provider.of<ParticipantColors?>(context, listen: listen);

/// The color of [personKey] in the current theme: from [store] when given,
/// else the default (D4).
Color participantColorOf(
  BuildContext context,
  String personKey,
  ParticipantColors? store,
) {
  final brightness = Theme.of(context).brightness;
  return store?.colorFor(personKey, brightness) ??
      participantPalette[defaultParticipantColorIndex(personKey)].forBrightness(
        brightness,
      );
}

/// The picker (D7): title, ten round swatches with their names as tooltip
/// and screen reader label, a check on the current one, and "Automatic".
/// The choice is stored right away; every listener repaints.
Future<void> showParticipantColorSheet(
  BuildContext context, {
  required ParticipantColors store,
  required String personKey,
  required String name,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) =>
      ParticipantColorSheet(store: store, personKey: personKey, name: name),
);

/// Body of [showParticipantColorSheet]; public for tests and screenshots.
class ParticipantColorSheet extends StatelessWidget {
  const ParticipantColorSheet({
    super.key,
    required this.store,
    required this.personKey,
    required this.name,
  });

  final ParticipantColors store;
  final String personKey;
  final String name;

  Future<void> _pick(BuildContext context, int? index) async {
    Navigator.of(context).pop();
    await store.setChoice(personKey, index);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final chosen = store.chosenIndex(personKey);
    final automatic =
        participantPalette[defaultParticipantColorIndex(personKey)]
            .forBrightness(brightness);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.participantColorTitle(name),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < participantPalette.length; i++)
                  _Swatch(
                    key: ValueKey('participant-color-$i'),
                    color: participantPalette[i].forBrightness(brightness),
                    label: participantColorName(l10n, i),
                    selected: chosen == i,
                    onTap: () => _pick(context, i),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              key: const ValueKey('participant-color-automatic'),
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(radius: 12, backgroundColor: automatic),
              title: Text(l10n.participantColorAutomatic),
              trailing: chosen == null ? const Icon(Icons.check_rounded) : null,
              selected: chosen == null,
              onTap: () => _pick(context, null),
            ),
          ],
        ),
      ),
    );
  }
}

/// One round swatch: an [IconButton] so it gets focus, keyboard activation
/// and a tooltip (= its semantics label) for free (D12).
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The check must be readable on the swatch in both themes: light tones
    // are dark and dark tones are light, so pick by the swatch itself.
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    // One explicit node (name, button, selected state): the tooltip alone
    // is announced as a hint, not as the name, and has no selected state.
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: IconButton(
        tooltip: label,
        isSelected: selected,
        onPressed: onTap,
        style: IconButton.styleFrom(
          backgroundColor: color,
          fixedSize: const Size.square(48),
          shape: CircleBorder(
            side: selected
                ? BorderSide(
                    color: Theme.of(context).colorScheme.onSurface,
                    width: 2,
                  )
                : BorderSide.none,
          ),
        ),
        icon: Icon(
          Icons.check_rounded,
          color: selected ? onColor : Colors.transparent,
        ),
      ),
    );
  }
}
