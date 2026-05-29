import 'package:flutter/material.dart';

import 'app/app.dart';

/// Application entry point.
///
/// Kept deliberately minimal — all configuration (theme, routing, DI)
/// lives in [ZMessangerApp] and its dependencies. This makes the app
/// easier to test (just pump ZMessangerApp) and avoids a bloated main().
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZMessangerApp());
}
