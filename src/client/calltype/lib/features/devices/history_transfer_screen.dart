import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import '../contacts/qr_scanner_screen.dart';
import 'history_transfer.dart';
import 'link_ux.dart';

/// Localized text of a [HistoryTransferError].
String historyTransferErrorText(
  AppLocalizations l10n,
  HistoryTransferError error,
) => switch (error) {
  HistoryTransferError.invalidCode => l10n.historyErrorInvalidCode,
  HistoryTransferError.notOwnDevice => l10n.historyErrorNotOwnDevice,
  HistoryTransferError.tooLarge => l10n.historyErrorTooLarge,
  HistoryTransferError.wrongKey => l10n.historyErrorWrongKey,
  HistoryTransferError.damaged => l10n.historyErrorDamaged,
  HistoryTransferError.expired => l10n.historyErrorExpired,
  HistoryTransferError.importFailed => l10n.historyErrorImportFailed,
  HistoryTransferError.timeout => l10n.historyErrorTimeout,
  HistoryTransferError.network => l10n.historyErrorNetwork,
};

/// Progress of a running transfer: a bar (determinate when known) and the
/// phase text, plus Cancel.
class _Progress extends StatelessWidget {
  const _Progress({required this.text, required this.onCancel, this.value});

  final String text;
  final double? value;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      LinearProgressIndicator(value: value),
      const SizedBox(height: 16),
      Text(text, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      TextButton(onPressed: onCancel, child: Text(context.l10n.commonCancel)),
    ],
  );
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.ok, required this.text, this.action});

  final bool ok;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
        size: 48,
      ),
      const SizedBox(height: 16),
      Text(text, textAlign: TextAlign.center),
      if (action != null) ...[const SizedBox(height: 16), action!],
    ],
  );
}

/// The device that should RECEIVE the history: shows the code (QR and
/// copyable text) and then the import progress. Leaving while the code is
/// shown drops the ephemeral key; a running download keeps going.
class HistoryReceiveScreen extends StatefulWidget {
  const HistoryReceiveScreen({super.key});

  @override
  State<HistoryReceiveScreen> createState() => _HistoryReceiveScreenState();
}

class _HistoryReceiveScreenState extends State<HistoryReceiveScreen> {
  late final HistoryTransferService _service;

  @override
  void initState() {
    super.initState();
    _service = context.read<HistoryTransferService>();
    // After the frame: the service notifies synchronously, which must not
    // happen while this widget is being mounted or unmounted.
    if (_service.role != HistoryTransferRole.target || !_service.busy) {
      Future.microtask(_service.startReceiving);
    }
  }

  @override
  void dispose() {
    final service = _service;
    if (service.phase == HistoryTransferPhase.showingCode) {
      Future.microtask(service.cancel);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<HistoryTransferService>();
    final l10n = context.l10n;
    final code = service.code;
    final Widget body = switch (service.phase) {
      HistoryTransferPhase.showingCode when code != null => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.historyReceiveInstructions, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: QrImageView(data: code, size: 240),
          ),
          const SizedBox(height: 24),
          Text(l10n.historyTextCodeHint, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          SelectableText(
            code,
            key: const ValueKey('historyTextCode'),
            textAlign: TextAlign.center,
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: Text(l10n.historyCopyCode),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: code));
              messenger.showSnackBar(
                SnackBar(content: Text(l10n.historyCodeCopied)),
              );
            },
          ),
        ],
      ),
      HistoryTransferPhase.downloading => _Progress(
        text: l10n.historyDownloading,
        value: service.progress,
        onCancel: service.cancel,
      ),
      HistoryTransferPhase.importing => _Progress(
        text: l10n.historyImporting,
        onCancel: service.cancel,
      ),
      HistoryTransferPhase.done => _Outcome(
        ok: true,
        text: l10n.historyReceivedDone(service.importedMessages),
      ),
      HistoryTransferPhase.failed => _Outcome(
        ok: false,
        text: historyTransferErrorText(l10n, service.error!),
        action: FilledButton(
          onPressed: service.startReceiving,
          child: Text(l10n.historyTryAgain),
        ),
      ),
      _ => const CircularProgressIndicator(),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.historyReceiveTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: body,
        ),
      ),
    );
  }
}

/// The device that HAS the history: scan or paste the target's code,
/// confirm the estimate, then upload and wait for the target.
class HistorySendScreen extends StatefulWidget {
  const HistorySendScreen({super.key, this.canScan});

  /// Overrides [canScanLinkCodes] (tests run on one platform only).
  final bool? canScan;

  @override
  State<HistorySendScreen> createState() => _HistorySendScreenState();
}

class _HistorySendScreenState extends State<HistorySendScreen> {
  final _pasted = TextEditingController();

  @override
  void initState() {
    super.initState();
    final service = context.read<HistoryTransferService>();
    // A finished transfer is not shown again; a running one (either role)
    // keeps going until the user starts a new one here.
    if (!service.busy) Future.microtask(service.cancel);
  }

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final service = context.read<HistoryTransferService>();
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(
        builder: (_) => const QrScannerScreen(historyTransfer: true),
      ),
    );
    final raw = result?['history'];
    if (raw != null) await service.prepare(raw);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<HistoryTransferService>();
    final l10n = context.l10n;
    final target = service.targetDeviceId;
    final Widget body = switch (service.phase) {
      HistoryTransferPhase.preparing => _Progress(
        text: l10n.historyPreparing,
        onCancel: service.cancel,
      ),
      HistoryTransferPhase.confirm when target != null => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.historyConfirm(
              service.chatCount,
              (service.archiveBytes / (1024 * 1024)).toStringAsFixed(1),
              l10n.devicesDeviceLabel(target.substring(0, 8)),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 16,
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                onPressed: service.cancel,
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                onPressed: service.confirm,
                child: Text(l10n.historyTransferButton),
              ),
            ],
          ),
        ],
      ),
      HistoryTransferPhase.uploading => _Progress(
        text: l10n.historyUploading,
        value: service.progress,
        onCancel: service.cancel,
      ),
      HistoryTransferPhase.waitingForTarget => _Progress(
        text: l10n.historyWaitingForTarget,
        onCancel: service.cancel,
      ),
      HistoryTransferPhase.done => _Outcome(
        ok: true,
        text: l10n.historySentDone,
      ),
      HistoryTransferPhase.failed => _Outcome(
        ok: false,
        text: historyTransferErrorText(l10n, service.error!),
        action: FilledButton(
          onPressed: service.cancel,
          child: Text(l10n.historyTryAgain),
        ),
      ),
      _ => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.historySendInstructions, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          if (widget.canScan ?? canScanLinkCodes)
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(l10n.historyScanCode),
              onPressed: _scan,
            ),
          const SizedBox(height: 24),
          TextField(
            key: const ValueKey('historyPasteField'),
            controller: _pasted,
            decoration: InputDecoration(
              labelText: l10n.historyPasteLabel,
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
            minLines: 1,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => service.prepare(_pasted.text),
              child: Text(l10n.historyContinue),
            ),
          ),
        ],
      ),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.historySendTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: body,
        ),
      ),
    );
  }
}
