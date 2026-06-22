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

  Future<void> scrollToMessage(String id, {double alignment = 0.12}) async {
    if (!scroll.hasClients) return;
    final key = messageKeys[id];
    if (key?.currentContext == null) {
      // Пробуем приблизительно прокрутить по индексу, чтобы элемент попал в кэш и отрисовался
      // Затем ещё раз ensureVisible после кадра
      try {
        // Маленький сдвиг для инициирования построения виджетов сверху/снизу
        final target = (scroll.position.pixels + 300).clamp(
            scroll.position.minScrollExtent, scroll.position.maxScrollExtent);
        await scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } catch (_) {}

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final retryKey = messageKeys[id];
        if (retryKey?.currentContext != null) {
          try {
            await Scrollable.ensureVisible(
              retryKey!.currentContext!,
              duration: const Duration(milliseconds: 260),
              alignment: alignment,
              curve: Curves.easeOutCubic,
            );
          } catch (_) {}
        }
      });
      return;
    }

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
        scroll.position.extentAfter <= 1 ||
        scroll.position.maxScrollExtent <= 0;
  }

  bool nearBottom({double threshold = 96}) {
    if (!scroll.hasClients) return true;
    final position = scroll.position;
    return position.pixels <= position.minScrollExtent + threshold ||
        position.extentAfter <= threshold ||
        position.maxScrollExtent <= 0;
  }
}
