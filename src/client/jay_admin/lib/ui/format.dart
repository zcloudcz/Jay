import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../api/admin_api.dart';
import '../api/models.dart';
import '../l10n/app_localizations.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
  String get lang => Localizations.localeOf(this).languageCode;
}

String ruleTitle(AppLocalizations l, String rule) => switch (rule) {
  'K1' => l.ruleK1,
  'K2' => l.ruleK2,
  'K3' => l.ruleK3,
  'K4' => l.ruleK4,
  'K5' => l.ruleK5,
  'K6' => l.ruleK6,
  'K7' => l.ruleK7,
  'K8' => l.ruleK8,
  'K9' => l.ruleK9,
  'K10' => l.ruleK10,
  _ => rule,
};

String categoryLabel(AppLocalizations l, String c) => switch (c) {
  'illegal' => l.categoryIllegal,
  'terms' => l.categoryTerms,
  'spam' => l.categorySpam,
  _ => c,
};

String actionLabel(AppLocalizations l, String a) => switch (a) {
  'dismiss' => l.actionDismiss,
  'remove_post' => l.actionRemovePost,
  'suspend_channel' => l.actionSuspend,
  'terminate_channel' => l.actionTerminate,
  'restore_channel' => l.actionRestore,
  _ => a,
};

String reportStatusLabel(AppLocalizations l, String s) => switch (s) {
  'open' => l.reportStatusOpen,
  'dismissed' => l.reportStatusDismissed,
  'actioned' => l.reportStatusActioned,
  _ => s,
};

String channelStatusLabel(AppLocalizations l, ChannelSummary c) => c.deleted
    ? l.channelTerminated
    : c.isSuspended
    ? l.channelSuspended
    : l.channelActive;

String groundShort(AppLocalizations l, Decision d) {
  if (d.ground == 'terms' && d.rule != null) {
    return '${l.groundRuleShort(d.rule!)} ${ruleTitle(l, d.rule!)}';
  }
  if (d.ground == 'illegal') return l.groundLawShort(d.legalGround ?? '');
  return '';
}

/// "3 hours" style age, rounded down to the largest whole unit.
String formatAge(AppLocalizations l, Duration d) {
  if (d.inDays >= 1) return l.ageDays(d.inDays);
  if (d.inHours >= 1) return l.ageHours(d.inHours);
  return l.ageMinutes(d.inMinutes < 1 ? 1 : d.inMinutes);
}

/// Local date + time; the API is UTC, the operator thinks in local time.
String formatDateTime(BuildContext context, DateTime t) =>
    DateFormat.yMd(context.lang).add_Hm().format(t.toLocal());

String formatDate(BuildContext context, DateTime t) =>
    DateFormat.yMd(context.lang).format(t.toLocal());

String formatCountdown(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Localized text for any error the API layer throws. Codes per contract
/// section 4; anything unknown still shows status + code so the operator can
/// report it instead of seeing a blank failure.
String errorMessage(AppLocalizations l, Object e) {
  if (e is AdminNetworkException) return l.errNetwork;
  if (e is AdminApiException) {
    switch (e.code) {
      case 'invalid_credentials':
        return l.errInvalidCredentials;
      case 'not_an_operator':
        return l.errNotAnOperator;
      case 'mfa_not_enabled':
        return l.errMfaNotEnabled;
      case 'mfa_invalid_code':
        return l.errMfaInvalidCode;
      case 'mfa_locked':
        return l.errMfaLocked;
      case 'not_suspended':
        return l.errNotSuspended;
      case 'already_removed':
        return l.errAlreadyRemoved;
    }
    if (e.statusCode == 429) return l.errTooManyRequests;
    if (e.statusCode == 404) return l.errNotFound;
    if (e.statusCode == 401 && e.code == null) return l.errInvalidCredentials;
    if (e.statusCode == 403) return l.errForbidden(e.code ?? '403');
    if (e.statusCode == 400 || e.statusCode == 409) {
      return l.errDecisionRefused(e.code ?? '${e.statusCode}');
    }
    return l.errUnknown(e.statusCode, e.code == null ? '' : ', ${e.code}');
  }
  return l.errUnknown(0, ', $e');
}

/// Input of the statement preview: exactly the fields the app shows the
/// owner (contract section 3, `Statement`), plus the channel label.
class StatementDraft {
  const StatementDraft({
    required this.action,
    required this.channelLabel,
    this.ground,
    this.rule,
    this.legalGround,
    this.explanation = '',
    this.suspendDays,
    this.basedOnReports = false,
  });

  final String action;
  final String channelLabel;
  final String? ground;
  final String? rule;
  final String? legalGround;
  final String explanation;
  final int? suspendDays;
  final bool basedOnReports;
}

/// The statement of reasons (DSA Art. 17) as the owner will read it, or
/// null for `dismiss` (the server returns no statement for it).
///
/// WHY it mirrors the app's wording instead of being free text: the operator
/// must see what actually reaches the owner (what, for how long, which rule
/// or law, facts, report-based or not, human decision, redress) before
/// pressing confirm. [now] is injectable so the "until" date is testable.
String? statementPreview(
  AppLocalizations l,
  String languageCode,
  StatementDraft d, {
  DateTime? now,
}) {
  final lines = <String>[];
  switch (d.action) {
    case 'remove_post':
      lines.add(l.stmtRemovePost(d.channelLabel));
    case 'suspend_channel':
      final days = d.suspendDays ?? 0;
      final until = (now ?? DateTime.now()).add(Duration(days: days));
      lines.add(
        l.stmtSuspend(d.channelLabel, days, DateFormat.yMd(languageCode).format(until.toLocal())),
      );
    case 'terminate_channel':
      lines.add(l.stmtTerminate(d.channelLabel));
    case 'restore_channel':
      lines.add(l.stmtRestore(d.channelLabel));
    default:
      return null;
  }
  if (d.action != 'restore_channel') {
    if (d.ground == 'terms' && d.rule != null) {
      lines.add(
        l.stmtGroundRule(d.rule!, ruleTitle(l, d.rule!), Rules.url(d.rule!, languageCode).toString()),
      );
    } else if (d.ground == 'illegal' && (d.legalGround ?? '').trim().isNotEmpty) {
      lines.add(l.stmtGroundLaw(d.legalGround!.trim()));
    }
  }
  if (d.explanation.trim().isNotEmpty) {
    lines.add(l.stmtExplanation(d.explanation.trim()));
  }
  lines.add(d.basedOnReports ? l.stmtBasedOnReports : l.stmtOwnInitiative);
  lines.add(l.stmtHuman);
  lines.add(l.stmtRedress);
  return lines.join('\n');
}
