import 'package:calltype/features/devices/history_transfer.dart';
import 'package:calltype/features/devices/history_transfer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';

const _code =
    'calltype://history-transfer?v=1&d=a0000000-0000-4000-8000-000000000002'
    '&t=00112233445566778899aabbccddeeff&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

/// The screens only read state and call the four actions; this stands in
/// for the service (its logic is covered by contact_sync_flow_test).
class _FakeTransfer extends ChangeNotifier implements HistoryTransferService {
  @override
  HistoryTransferRole role = HistoryTransferRole.none;
  @override
  HistoryTransferPhase phase = HistoryTransferPhase.idle;
  @override
  HistoryTransferError? error;
  @override
  String? code;
  @override
  String? targetDeviceId;
  @override
  int chatCount = 0;
  @override
  int archiveBytes = 0;
  @override
  int importedMessages = 0;
  @override
  double? progress;

  final calls = <String>[];

  void set(HistoryTransferPhase next) {
    phase = next;
    notifyListeners();
  }

  @override
  bool get busy =>
      phase != HistoryTransferPhase.idle &&
      phase != HistoryTransferPhase.done &&
      phase != HistoryTransferPhase.failed;

  @override
  void start() {}

  @override
  Future<String> startReceiving() async {
    calls.add('startReceiving');
    role = HistoryTransferRole.target;
    code = _code;
    set(HistoryTransferPhase.showingCode);
    return _code;
  }

  @override
  Future<HistoryTransferError?> prepare(String raw) async {
    calls.add('prepare:$raw');
    return null;
  }

  @override
  Future<void> confirm() async => calls.add('confirm');

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    role = HistoryTransferRole.none;
    code = null;
    set(HistoryTransferPhase.idle);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeTransfer service;

  setUp(() => service = _FakeTransfer());

  Future<void> pump(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<HistoryTransferService>.value(
        value: service,
        child: localizedApp(home: screen),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('receive screen', () {
    testWidgets('shows the QR code and the copyable text code', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      await pump(tester, const HistoryReceiveScreen());

      expect(service.calls, ['startReceiving']);
      expect(find.text(l10nEn.historyReceiveInstructions), findsOneWidget);
      expect(find.text(l10nEn.historyTextCodeHint), findsOneWidget);
      expect(find.byKey(const ValueKey('historyTextCode')), findsOneWidget);
      expect(find.text(_code), findsOneWidget);

      await tester.tap(find.text(l10nEn.historyCopyCode));
      await tester.pump();
      expect(copied, [_code]);
      expect(find.text(l10nEn.historyCodeCopied), findsOneWidget);
    });

    testWidgets('leaving while the code is shown drops it', (tester) async {
      await pump(tester, const HistoryReceiveScreen());
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(service.calls, ['startReceiving', 'cancel']);
    });

    testWidgets('progress, success and the error texts', (tester) async {
      await pump(tester, const HistoryReceiveScreen());
      service
        ..progress = 0.4
        ..set(HistoryTransferPhase.downloading);
      await tester.pump();
      expect(find.text(l10nEn.historyDownloading), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);

      service.set(HistoryTransferPhase.importing);
      await tester.pump();
      expect(find.text(l10nEn.historyImporting), findsOneWidget);

      service
        ..importedMessages = 42
        ..set(HistoryTransferPhase.done);
      await tester.pump();
      expect(find.text(l10nEn.historyReceivedDone(42)), findsOneWidget);

      for (final error in HistoryTransferError.values) {
        service
          ..error = error
          ..set(HistoryTransferPhase.failed);
        await tester.pump();
        expect(
          find.text(historyTransferErrorText(l10nEn, error)),
          findsOneWidget,
          reason: '$error',
        );
      }
      await tester.tap(find.text(l10nEn.historyTryAgain));
      await tester.pump();
      expect(service.calls.last, 'startReceiving');
    });
  });

  group('send screen', () {
    testWidgets('a pasted code is prepared; the camera only where it exists', (
      tester,
    ) async {
      await pump(tester, const HistorySendScreen(canScan: false));
      expect(find.text(l10nEn.historySendInstructions), findsOneWidget);
      expect(find.text(l10nEn.historyScanCode), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('historyPasteField')),
        _code,
      );
      await tester.tap(find.text(l10nEn.historyContinue));
      await tester.pump();
      expect(service.calls.last, 'prepare:$_code');

      await pump(tester, const HistorySendScreen(canScan: true));
      expect(find.text(l10nEn.historyScanCode), findsOneWidget);
    });

    testWidgets('the confirmation shows the estimate and starts on Transfer', (
      tester,
    ) async {
      await pump(tester, const HistorySendScreen(canScan: false));
      service
        ..role = HistoryTransferRole.source
        ..targetDeviceId = 'a0000000-0000-4000-8000-000000000002'
        ..chatCount = 12
        ..archiveBytes = 3 * 1024 * 1024 + 300 * 1024
        ..set(HistoryTransferPhase.confirm);
      await tester.pump();

      expect(
        find.text(
          l10nEn.historyConfirm(
            12,
            '3.3',
            l10nEn.devicesDeviceLabel('a0000000'),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(l10nEn.historyTransferButton));
      await tester.pump();
      expect(service.calls.last, 'confirm');

      service
        ..progress = 0.5
        ..set(HistoryTransferPhase.uploading);
      await tester.pump();
      expect(find.text(l10nEn.historyUploading), findsOneWidget);

      service.set(HistoryTransferPhase.waitingForTarget);
      await tester.pump();
      expect(find.text(l10nEn.historyWaitingForTarget), findsOneWidget);
      await tester.tap(find.text(l10nEn.commonCancel));
      await tester.pump();
      expect(service.calls.last, 'cancel');

      service.set(HistoryTransferPhase.done);
      await tester.pump();
      expect(find.text(l10nEn.historySentDone), findsOneWidget);

      service
        ..error = HistoryTransferError.notOwnDevice
        ..set(HistoryTransferPhase.failed);
      await tester.pump();
      expect(find.text(l10nEn.historyErrorNotOwnDevice), findsOneWidget);
    });
  });
}
