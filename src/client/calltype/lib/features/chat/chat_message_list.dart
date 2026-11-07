import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// The message list of a chat (newest at the bottom) with a "jump to
/// latest" button, like WhatsApp and Telegram.
///
/// WHY a center-keyed [CustomScrollView] instead of `ListView(reverse:
/// true)`: in a reversed list a new message is inserted at the scroll
/// origin, so everything above it moves up by its height and a user who is
/// reading history loses their place. Here, once the user scrolls away from
/// the newest message, that message becomes the anchor (the center sliver)
/// and later messages go into a sliver that grows BELOW the anchor, into
/// negative scroll offsets. The pixels on screen do not move, no item
/// heights need to be known, and the button counts what arrived meanwhile.
/// Back at the bottom (or on the button tap, or when the user sends) the
/// anchor is dropped again and the list follows new messages as before.
class ChatMessageList<T> extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.items,
    required this.idOf,
    required this.isMine,
    required this.itemBuilder,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  /// Newest first, the same order the chat controller keeps.
  final List<T> items;
  final String Function(T item) idOf;

  /// An own message: arriving below the anchor it scrolls to the bottom
  /// (the user just sent it), and it never counts as new.
  final bool Function(T item) isMine;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final EdgeInsets padding;

  @override
  State<ChatMessageList<T>> createState() => _ChatMessageListState<T>();
}

class _ChatMessageListState<T> extends State<ChatMessageList<T>> {
  final _scroll = ScrollController();
  final _centerKey = UniqueKey();

  /// Id of the message the view is anchored to; null = following the
  /// newest message.
  String? _anchorId;
  bool _showButton = false;

  /// Below this distance from the newest message the list counts as being
  /// at the bottom (float rounding of the scroll physics).
  static const _bottomSlack = 1.0;

  /// Distance from the bottom at which the button shows even without new
  /// messages: about one screen, as asked.
  double _buttonDistance(ScrollMetrics m) => m.viewportDimension;

  /// Index of the anchor in [ChatMessageList.items]: the items before it are
  /// newer and render below the anchor. 0 when not anchored (or the anchor
  /// message is gone, e.g. deleted for me).
  int get _anchorIndex {
    final anchor = _anchorId;
    if (anchor == null) return 0;
    final index = widget.items.indexWhere((i) => widget.idOf(i) == anchor);
    return index < 0 ? 0 : index;
  }

  int get _newCount => widget.items
      .take(_anchorIndex)
      .where((item) => !widget.isMine(item))
      .length;

  @override
  void didUpdateWidget(ChatMessageList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_anchorId == null) return;
    final newer = widget.items.take(_anchorIndex);
    if (newer.any(widget.isMine)) {
      // The user sent something while reading history: show it.
      _anchorId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    _handleMetrics(n.metrics);
    if (n is ScrollEndNotification && _atBottom(n.metrics)) _dropAnchor();
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    _handleMetrics(n.metrics);
    return false;
  }

  bool _atBottom(ScrollMetrics m) =>
      m.pixels - m.minScrollExtent <= _bottomSlack;

  void _handleMetrics(ScrollMetrics m) {
    if (m.axis != Axis.vertical) return;
    final distance = m.pixels - m.minScrollExtent;
    if (_anchorId == null &&
        distance > _bottomSlack &&
        widget.items.isNotEmpty) {
      // Same layout (nothing is newer yet); only later arrivals change.
      _anchorId = widget.idOf(widget.items.first);
    }
    final show =
        distance > _buttonDistance(m) ||
        (_newCount > 0 && distance > _bottomSlack);
    if (show != _showButton) setState(() => _showButton = show);
  }

  /// Moves the newer items back into the center sliver without a visible
  /// jump: the viewport keeps the same distance from the newest message.
  void _dropAnchor() {
    if (_anchorId == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    final fromBottom = position.pixels - position.minScrollExtent;
    final hadNewer = _anchorIndex > 0;
    setState(() {
      _anchorId = null;
      _showButton = false;
    });
    if (hadNewer) position.correctPixels(fromBottom);
  }

  Future<void> _scrollToLatest() async {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = position.minScrollExtent;
    // Far away: jump to one screen above the bottom first, so the animation
    // stays short instead of building every message in between.
    final screen = position.viewportDimension;
    if (position.pixels - target > 3 * screen) {
      position.jumpTo(target + screen);
    }
    await position.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    if (mounted) _dropAnchor();
  }

  @override
  Widget build(BuildContext context) {
    final anchor = _anchorIndex;
    final items = widget.items;
    // Closest to the anchor first: a sliver before the center grows away
    // from it, downwards here.
    final newer = items.sublist(0, anchor).reversed.toList();
    final older = items.sublist(anchor);
    final count = _newCount;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: _onMetrics,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: CustomScrollView(
              controller: _scroll,
              reverse: true,
              center: _centerKey,
              slivers: [
                SliverList.builder(
                  itemCount: newer.length,
                  itemBuilder: (context, i) =>
                      widget.itemBuilder(context, newer[i]),
                ),
                SliverPadding(
                  key: _centerKey,
                  padding: widget.padding,
                  sliver: SliverList.builder(
                    itemCount: older.length,
                    itemBuilder: (context, i) =>
                        widget.itemBuilder(context, older[i]),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showButton)
          Positioned(
            right: 12,
            bottom: 12,
            child: _JumpToLatestButton(
              newCount: count,
              onPressed: _scrollToLatest,
            ),
          ),
      ],
    );
  }
}

class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.newCount, required this.onPressed});

  final int newCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final label = newCount > 0
        ? '${l10n.chatJumpToLatest}, ${l10n.chatNewMessagesBadge(newCount)}'
        : l10n.chatJumpToLatest;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: l10n.chatJumpToLatest,
        child: Badge(
          key: const ValueKey('chat-jump-to-latest-badge'),
          isLabelVisible: newCount > 0,
          label: Text(newCount > 99 ? '99+' : '$newCount'),
          child: FloatingActionButton.small(
            key: const ValueKey('chat-jump-to-latest'),
            heroTag: null,
            elevation: 2,
            backgroundColor: colors.surfaceContainerHigh,
            foregroundColor: colors.onSurface,
            onPressed: onPressed,
            child: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ),
      ),
    );
  }
}
