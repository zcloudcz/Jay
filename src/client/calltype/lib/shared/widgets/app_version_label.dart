import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/l10n.dart';

/// Full commit SHA of this build (release workflows pass
/// `--dart-define=JAY_COMMIT_SHA=…`, contract X0-P7); '' in dev builds.
const String jayCommitSha = String.fromEnvironment('JAY_COMMIT_SHA');

/// Shows "Jay 1.2.0 (142) beta" from the real bundle metadata.
///
/// Replaces the hard-coded '1.0.0' in the settings screen, which was wrong on
/// every build after the first. The build name and number come from
/// `--build-name/--build-number` set by .github/scripts/version.sh, so the
/// label matches the build manifest of the store / web artifact
/// (acceptance R-04). On the web package_info_plus reads the `version.json`
/// that `flutter build web` writes, which is why the web build gets the same
/// flags.
class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({
    super.key,
    this.loader = PackageInfo.fromPlatform,
    this.commitSha = jayCommitSha,
  });

  /// Injected for tests; the app always uses [PackageInfo.fromPlatform].
  final Future<PackageInfo> Function() loader;

  /// Shown shortened in a tooltip so a bug report can name the exact commit.
  final String commitSha;

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  // Loaded once: FutureBuilder with `future: loader()` in build() would
  // restart the platform call and blank the label on every rebuild.
  late final Future<PackageInfo> _info = widget.loader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        // While loading or on error show nothing: a placeholder like
        // settingsVersion('') would read "Jay  beta", which is worse than no
        // label, and a failed platform call must not break the settings page.
        if (info == null || snapshot.hasError) return const SizedBox.shrink();
        final label = Text(
          context.l10n.settingsVersion('${info.version} (${info.buildNumber})'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
        final sha = widget.commitSha.trim();
        if (sha.isEmpty) return label;
        return Tooltip(
          message: sha.length > 7 ? sha.substring(0, 7) : sha,
          child: label,
        );
      },
    );
  }
}
