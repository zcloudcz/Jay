import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'api/admin_api.dart';
import 'app.dart';
import 'config.dart';
import 'session.dart';

void main() {
  // Hash routes (/admin/#/queue): the Static Web App only has to serve
  // /admin/index.html for /admin and /admin/; every deep link stays a
  // fragment the server never sees, so no rewrite can leak into the app's
  // own navigation fallback.
  setUrlStrategy(const HashUrlStrategy());

  final baseUrl = configuredApiBaseUrl;
  final api = AdminApi(baseUrl: baseUrl);
  runApp(
    AdminApp(
      api: api,
      session: SessionController(api),
      configError: validateApiBaseUrl(baseUrl),
    ),
  );
}
