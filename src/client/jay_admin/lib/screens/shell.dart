import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../session.dart';
import '../ui/format.dart';

/// Frame of every signed-in screen: navigation rail, session countdown,
/// logout.
class AdminShell extends StatelessWidget {
  const AdminShell({super.key, required this.location, required this.child});

  final Uri location;
  final Widget child;

  static const _paths = ['/overview', '/queue', '/channels', '/audit'];

  int get _index {
    final p = location.path;
    if (p.startsWith('/case')) return 1;
    final i = _paths.indexWhere(p.startsWith);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scope = AdminScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        actions: [
          SessionCountdown(session: scope.session),
          const SizedBox(width: 8),
          if (scope.session.session != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(child: Text(scope.session.session!.email)),
            ),
          IconButton(
            key: const Key('logout'),
            tooltip: l.logout,
            icon: const Icon(Icons.logout),
            onPressed: () => scope.session.end(LogoutReason.manual),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => context.go(_paths[i]),
            destinations: [
              NavigationRailDestination(icon: const Icon(Icons.dashboard_outlined), label: Text(l.navOverview)),
              NavigationRailDestination(icon: const Icon(Icons.flag_outlined), label: Text(l.navQueue)),
              NavigationRailDestination(icon: const Icon(Icons.campaign_outlined), label: Text(l.navChannels)),
              NavigationRailDestination(icon: const Icon(Icons.history), label: Text(l.navAudit)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// "Session 29:58". Owns the one-second timer and ends the session locally
/// when time is up, so the operator is sent to the login before the next
/// request would fail with 401 half-way through writing a decision.
class SessionCountdown extends StatefulWidget {
  const SessionCountdown({super.key, required this.session});

  final SessionController session;

  @override
  State<SessionCountdown> createState() => _SessionCountdownState();
}

class _SessionCountdownState extends State<SessionCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!widget.session.expireIfDue() && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.session.remaining;
    final warn = left < const Duration(minutes: 5);
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      key: const Key('session-countdown'),
      avatar: Icon(Icons.timer_outlined, size: 18, color: warn ? scheme.error : null),
      label: Text(
        context.l10n.sessionRemaining(formatCountdown(left)),
        style: warn ? TextStyle(color: scheme.error) : null,
      ),
    );
  }
}
