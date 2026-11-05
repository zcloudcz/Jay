import 'package:calltype_core/network/channel_dtos.dart' show parseChannelLink;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../devices/link_code.dart';

/// Full-screen QR code scanner for adding contacts.
///
/// Scans for QR codes containing the CallType contact URI:
///   calltype://contact/{handle}
/// or the device-pairing format from OnboardingScreen:
///   ct://{deviceId}/{handle}
///
/// When a valid code is detected, the screen pops and returns the
/// parsed handle string to the caller via Navigator.pop(). The caller
/// (typically ContactsScreen) then uses ContactsController.addContactByHandle
/// to persist the new contact.
///
/// Uses the `mobile_scanner` package which provides a unified camera API
/// across iOS/Android with ML Kit barcode detection. The scanner is
/// automatically paused when a valid code is found to prevent duplicate
/// processing of the same QR code.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key, this.deviceLink = false});

  /// Multi-device "Link a device": accept ONLY `jaylink://` codes, returned
  /// as {'link': raw}. The contact mode never accepts them (and this mode
  /// accepts no contact invites), so neither scan can be mistaken for the
  /// other.
  final bool deviceLink;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final _controller = MobileScannerController();

  /// Tracks whether we've already processed a code to prevent the callback
  /// from firing multiple times for the same QR code (the scanner can
  /// detect the same code on consecutive frames).
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.qrScanTitle)),
      body: Stack(
        children: [
          // Camera preview with barcode detection.
          MobileScanner(controller: _controller, onDetect: _onDetect),

          // Overlay hint text at the bottom — helps the user understand
          // what to scan without obscuring the camera viewfinder.
          Positioned(
            left: 0,
            right: 0,
            bottom: 48,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(
                  widget.deviceLink
                      ? context.l10n.devicesScanHint
                      : context.l10n.qrScanHint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Processes detected barcodes from the camera feed.
  ///
  /// Supports two URI formats:
  ///   - calltype://contact/{handle} (canonical)
  ///   - ct://{deviceId}/{handle} (onboarding QR format)
  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      final result = widget.deviceLink
          ? (LinkCode.parse(raw) == null ? null : {'link': raw})
          : _parseContactUri(raw);
      if (result != null) {
        _handled = true;
        _controller.stop();

        // Return the parsed handle to the calling screen.
        Navigator.of(context).pop(result);
        return;
      }
    }
  }

  /// Attempts to parse a CallType contact URI from a QR code payload.
  ///
  /// Returns a map with 'handle' and optionally 'deviceId' if the URI
  /// contains both. Returns null if the payload doesn't match any known format.
  Map<String, String>? _parseContactUri(String raw) {
    // Channel QR: calltype://channel/{handle}. Returned under a separate key
    // so the caller opens the channel profile instead of adding a contact.
    final channel = parseChannelLink(raw);
    if (channel != null) return {'channel': channel};

    // Format: calltype://contact/{handle}
    final contactUri = Uri.tryParse(raw);
    if (contactUri != null &&
        contactUri.scheme == 'calltype' &&
        contactUri.host == 'contact' &&
        contactUri.pathSegments.isNotEmpty) {
      return {'handle': contactUri.pathSegments.first};
    }

    // Device-pairing format from OnboardingScreen: ct://{deviceId}/{handle}
    if (raw.startsWith('ct://')) {
      final parts = raw.substring('ct://'.length).split('/');
      if (parts.length >= 2) {
        return {'deviceId': parts[0], 'handle': parts[1]};
      }
    }

    return null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
