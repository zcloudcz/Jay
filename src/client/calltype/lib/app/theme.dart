import 'package:flutter/material.dart';

/// App-wide Material 3 theme configuration.
///
/// Seeded from the Jay brand petrol (#003840, same as the logo and website);
/// Material 3 derives the full tonal palette from it for light and dark.
/// The brand orange (#FF8545, the jay's beak) is pinned as the tertiary
/// accent so highlights match the mark instead of a generated hue.
class AppTheme {
  AppTheme._(); // Prevent instantiation.

  static const _seed = Color(0xFF003840);
  static const _accent = Color(0xFFFF8545);

  static final light = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      tertiary: _accent,
      brightness: Brightness.light,
    ),
    useMaterial3: true,
  );

  static final dark = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seed,
      tertiary: _accent,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );
}
