import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class ChatScrollAnchor {
  final double pixels;
  final double maxScrollExtent;

  const ChatScrollAnchor({
    required this.pixels,
    required this.maxScrollExtent,
  });
}

class ChatScrollController {
  final ScrollController scroll;
  final Map<String, GlobalKey> messageKeys;
  final TickerProvider? vsync;
  int _viewportChange = 0;

  ChatScrollController(this.scroll, this.messageKeys, {this.vsync});

  GlobalKey keyFor(String id) => messageKeys.putIfAbsent(id, () => GlobalKey());

  Future<void> jumpToBottom() async {
    if (!scroll.hasClients) return;
    await scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  ChatScrollAnchor? capturePrependAnchor() {
    if (!scroll.hasClients) return null;
    final position = scroll.position;
    return ChatScrollAnchor(
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
    );
  }

  Future<void> restorePrependAnchor(ChatScrollAnchor? anchor) async {
    if (anchor == null) return;

    await WidgetsBinding.instance.endOfFrame;
    if (!scroll.hasClients) return;

    final position = scroll.position;
    final delta = position.maxScrollExtent - anchor.maxScrollExtent;
    if (delta.abs() < 0.5) return;

    final target = (anchor.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    scroll.jumpTo(target.toDouble());
  }

  /// Holds the visible history still as the selection header and footer swap.
  void keepVisibleMessage(VoidCallback change) {
    final revision = ++_viewportChange;
    final position = scroll.hasClients ? scroll.position : null;
    if (position == null || position.isScrollingNotifier.value) {
      change();
      return;
    }

    final pixels = position.pixels;
    RenderBox? anchor;
    double? anchorY;
    var nearest = double.infinity;

    for (final key in messageKeys.values) {
      // The marker is zero-height. Its enclosing row can still be visible
      // when a long message starts above the viewport.
      final row = key.currentContext?.findRenderObject()?.parent;
      if (row is! RenderBox || !row.attached || !row.hasSize) continue;
      final viewport = RenderAbstractViewport.maybeOf(row);
      if (viewport is! RenderBox) continue;
      final box = viewport as RenderBox;
      if (!box.hasSize) continue;
      final height = box.size.height;
      final top = row.localToGlobal(Offset.zero, ancestor: box).dy;
      final bottom = top + row.size.height;
      if (!top.isFinite || bottom <= 0 || top >= height || top == bottom) continue;
      final visibleCenter = (top.clamp(0, height) + bottom.clamp(0, height)) / 2;
      final distance = (visibleCenter - height / 2).abs();
      if (distance < nearest) {
        nearest = distance;
        anchor = row;
        anchorY = row.localToGlobal(Offset.zero).dy;
      }
    }

    change();

    if (anchor == null || anchorY == null) return;
    final row = anchor;
    final originalY = anchorY;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (revision != _viewportChange ||
          !scroll.hasClients ||
          scroll.position != position ||
          !row.attached ||
          position.isScrollingNotifier.value ||
          (position.pixels - pixels).abs() > 1) {
        return;
      }
      final difference = originalY - row.localToGlobal(Offset.zero).dy;
      if (!difference.isFinite || difference.abs() < .5) return;
      final direction = position.axisDirection == AxisDirection.up ? 1 : -1;
      final target = (position.pixels + difference * direction).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() >= .5) position.jumpTo(target);
    });
  }

  Future<void> scrollToMessage(
    String id, {
    double alignment = 0.12,
    List<String>? orderedIds,
    bool Function()? isCurrent,
  }) async {
    bool active() => scroll.hasClients && (isCurrent?.call() ?? true);
    if (!active()) return;

    if (messageKeys[id]?.currentContext == null) {
      if (orderedIds == null) {
        final position = scroll.position;
        await scroll.animateTo(
          (position.pixels + 300).clamp(position.minScrollExtent, position.maxScrollExtent),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
        await WidgetsBinding.instance.endOfFrame;
      } else {
        final targetIndex = orderedIds.indexOf(id);
        if (targetIndex < 0 || orderedIds.length < 2) return;
        // In a reversed list larger offsets show older messages. Estimate once,
        // then narrow the offset interval using rows actually built each frame.
        final index = {for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i};
        var low = scroll.position.minScrollExtent;
        var high = scroll.position.maxScrollExtent;
        var offset = high - (high - low) * targetIndex / (orderedIds.length - 1);
        for (var frame = 0; frame < 24 && active(); frame++) {
          final previousMax = scroll.position.maxScrollExtent;
          scroll.jumpTo(offset.clamp(scroll.position.minScrollExtent, previousMax));
          await WidgetsBinding.instance.endOfFrame;
          if (!active() || messageKeys[id]?.currentContext != null) break;
          int? mountedIndex;
          for (final entry in messageKeys.entries) {
            if (entry.value.currentContext != null && index.containsKey(entry.key)) {
              mountedIndex = index[entry.key];
              break;
            }
          }
          if (mountedIndex == null) return;
          if (targetIndex < mountedIndex) {
            low = scroll.position.pixels;
            if (high == previousMax) high = scroll.position.maxScrollExtent;
          } else {
            high = scroll.position.pixels;
          }
          if (high - low < 0.5) return;
          offset = (low + high) / 2;
        }
      }
    }
    if (!active()) return;
    final key = messageKeys[id];
    if (key?.currentContext == null) return;

    // Precise positioning via RenderObject
    try {
      final ro = key!.currentContext!.findRenderObject();
      if (ro != null) {
        final viewport = RenderAbstractViewport.of(ro);
        final revealedOffset = viewport.getOffsetToReveal(ro, alignment);

        // Skip small deltas
        final current = scroll.position.pixels;
        final diff = (revealedOffset.offset - current).abs();
        if (diff > 20) {
          await scroll.animateTo(
            revealedOffset.offset.clamp(0.0, scroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          );
        }
        return;
      }
    } catch (_) {}

    // Fallback
    try {
      await Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 260),
        alignment: alignment,
        curve: Curves.easeOutCubic,
      );
    } catch (_) {}
  }

  bool atBottom() {
    if (!scroll.hasClients) return true;
    return (scroll.position.pixels <=
            (scroll.position.minScrollExtent + 0.5)) ||
        scroll.position.maxScrollExtent <= 0;
  }

  bool nearBottom({double threshold = 96}) {
    if (!scroll.hasClients) return true;
    final position = scroll.position;
    return position.pixels <= position.minScrollExtent + threshold ||
        position.maxScrollExtent <= 0;
  }
}
