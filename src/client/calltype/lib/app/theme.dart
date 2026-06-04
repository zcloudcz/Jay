import 'package:flutter/material.dart';

/// App-wide Material 3 theme configuration.
///
/// Uses a green seed color to match the messenger brand identity — green
/// is conventionally associated with messaging apps (WhatsApp, Messages)
/// and conveys trust/security, which fits the E2EE positioning.
class AppTheme {
  AppTheme._(); // Prevent instantiation.

  static const _seed = Color(0xFF1B8755);

  static final light = ThemeData(
    colorSchemeSeed: _seed,
    brightness: Brightness.light,
    useMaterial3: true,
  );

  static final dark = ThemeData(
    colorSchemeSeed: _seed,
    brightness: Brightness.dark,
    useMaterial3: true,
  );
}
