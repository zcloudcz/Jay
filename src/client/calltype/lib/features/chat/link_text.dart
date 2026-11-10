import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import 'links.dart';

/// Opens a link; true when the platform accepted it.
typedef LinkLauncher = Future<bool> Function(Uri uri);

/// Default [LinkLauncher]: the system browser or mail app, on web a new tab
/// (spec 2026-11-10-clickable-links D8). Refuses every scheme except http,
/// https and mailto, also when a caller passes such a Uri by mistake.
Future<bool> launchExternalLink(Uri uri) async {
  if (!isOpenableLink(uri)) return false;
  return launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: '_blank',
  );
}

/// Test seam for widgets that do not take a launcher themselves (channel
/// posts): when set, every [LinkifiedText] without its own launcher uses it.
@visibleForTesting
LinkLauncher? debugLinkLauncherOverride;

/// Message text with tappable links (http/https/www/e-mail).
///
/// Tap opens the link. Long press (touch) or right click (mouse) on a link
/// opens a small sheet with "Open link" / "Copy link"; long press elsewhere
/// calls [onLongPressOutsideLink] (the message menu). A text without links
/// renders as a plain [Text], exactly as before.
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    required this.linkColor,
    this.onLongPressOutsideLink,
    this.launcher,
    this.selectable = false,
  });

  final String text;
  final TextStyle? style;

  /// Color of link text and underline (D12).
  final Color linkColor;

  /// Long press outside a link. Null = nothing happens there.
  final VoidCallback? onLongPressOutsideLink;

  /// Overrides [launchExternalLink] (tests).
  final LinkLauncher? launcher;

  /// Renders a [SelectableText] (channel posts, D11): links open on tap,
  /// long press keeps selecting text, there is no link sheet.
  final bool selectable;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final _textKey = GlobalKey();
  List<TextLink> _links = const [];
  List<TapGestureRecognizer> _recognizers = const [];

  @override
  void initState() {
    super.initState();
    _detect();
  }

  @override
  void didUpdateWidget(LinkifiedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.selectable != widget.selectable) {
      _disposeRecognizers();
      _detect();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers = const [];
  }

  /// Runs the detector once per text, not per frame (D6).
  void _detect() {
    _links = detectLinks(widget.text);
    _recognizers = [for (final link in _links) _recognizerFor(link)];
  }

  TapGestureRecognizer _recognizerFor(TextLink link) {
    final recognizer = TapGestureRecognizer()..onTap = () => _open(link);
    if (!widget.selectable) {
      recognizer.onSecondaryTapUp = (_) => _showLinkSheet(link);
    }
    return recognizer;
  }

  LinkLauncher get _launcher =>
      widget.launcher ?? debugLinkLauncherOverride ?? launchExternalLink;

  Future<void> _open(TextLink link) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.chatLinkOpenFailed;
    var ok = false;
    try {
      ok = await _launcher(link.uri);
    } catch (_) {
      ok = false;
    }
    if (!ok) messenger?.showSnackBar(SnackBar(content: Text(failed)));
  }

  void _copy(TextLink link) {
    // Started synchronously inside the tap handler: browsers only allow
    // clipboard writes within a user gesture.
    Clipboard.setData(ClipboardData(text: link.text));
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(context.l10n.chatLinkCopied)));
  }

  void _showLinkSheet(TextLink link) {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The full target, wrapped, never shortened (D9).
              Padding(
                key: const Key('link-sheet-url'),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  link.text,
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: Text(l10n.chatLinkOpen),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _open(link);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: Text(l10n.chatLinkCopy),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _copy(link);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The link under [global], by the glyph boxes of the laid-out paragraph.
  TextLink? _linkAt(Offset global) {
    final paragraph = _findParagraph(
      _textKey.currentContext?.findRenderObject(),
    );
    if (paragraph == null) return null;
    final local = paragraph.globalToLocal(global);
    for (final link in _links) {
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      );
      for (final box in boxes) {
        if (box.toRect().inflate(2).contains(local)) return link;
      }
    }
    return null;
  }

  static RenderParagraph? _findParagraph(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node.visitChildren((child) => found ??= _findParagraph(child));
    return found;
  }

  TextSpan _span() {
    final text = widget.text;
    final linkStyle = TextStyle(
      color: widget.linkColor,
      decoration: TextDecoration.underline,
      decorationColor: widget.linkColor,
    );
    final children = <InlineSpan>[];
    var pos = 0;
    for (var i = 0; i < _links.length; i++) {
      final link = _links[i];
      if (link.start > pos) {
        children.add(TextSpan(text: text.substring(pos, link.start)));
      }
      children.add(
        TextSpan(
          text: link.text,
          style: linkStyle,
          recognizer: _recognizers[i],
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      pos = link.end;
    }
    if (pos < text.length) children.add(TextSpan(text: text.substring(pos)));
    return TextSpan(children: children);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectable) {
      return _links.isEmpty
          ? SelectableText(widget.text, style: widget.style)
          : SelectableText.rich(_span(), style: widget.style);
    }
    if (_links.isEmpty) return Text(widget.text, style: widget.style);
    return GestureDetector(
      // Wins the long press over the bubble's own detector, so it has to
      // forward a long press outside a link to the message menu itself.
      onLongPressStart: (details) {
        final link = _linkAt(details.globalPosition);
        if (link != null) {
          _showLinkSheet(link);
        } else {
          widget.onLongPressOutsideLink?.call();
        }
      },
      child: Text.rich(_span(), key: _textKey, style: widget.style),
    );
  }
}
