import 'dart:async';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;

/// QA experiment: the same image subtree is mounted behind a bounded cover.
/// It does not authorize images, cache pixels, or change their error handling.
class ReentryImageGate extends StatefulWidget {
  const ReentryImageGate(
      {super.key,
      required this.child,
      this.initiallyArmed = true,
      this.readyForReveal = true,
      this.timeout = const Duration(milliseconds: 1200)});
  final Widget child;

  /// Decided once: a late snapshot must never hide an already visible chat.
  final bool initiallyArmed;
  final bool readyForReveal;
  final Duration timeout;
  @override
  State<ReentryImageGate> createState() => _ReentryImageGateState();
}

class _ReentryImageGateState extends State<ReentryImageGate> {
  final _observer = ReentryImageObserver();
  Timer? _timer;
  late bool _revealed;

  @override
  void initState() {
    super.initState();
    _revealed = !widget.initiallyArmed;
    _observer.onChanged = _scheduleCheck;
    _timer = Timer(widget.timeout, _reveal);
    _scheduleCheck();
  }

  void _scheduleCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_revealed &&
          widget.readyForReveal &&
          _observer.pending == 0) _reveal();
    });
  }

  @override
  void didUpdateWidget(covariant ReentryImageGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.readyForReveal && widget.readyForReveal) _scheduleCheck();
  }

  void _reveal() {
    if (!mounted || _revealed) return;
    _timer?.cancel();
    setState(() => _revealed = true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _observer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ReentryImageScope(
      observer: _observer,
      child: Stack(fit: StackFit.expand, children: [
        IgnorePointer(
            ignoring: !_revealed,
            child: ExcludeSemantics(
                excluding: !_revealed,
                child:
                    Opacity(opacity: _revealed ? 1 : 0, child: widget.child))),
        if (!_revealed) const Center(child: ProductLoadingIndicator(size: 72)),
      ]));
}

class ReentryImageScope extends InheritedWidget {
  const ReentryImageScope(
      {super.key, required this.observer, required super.child});
  final ReentryImageObserver observer;
  static ReentryImageObserver? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReentryImageScope>()?.observer;
  @override
  bool updateShouldNotify(ReentryImageScope oldWidget) =>
      !identical(observer, oldWidget.observer);
}

class ReentryImageObserver {
  final _pending = <Object>{};
  bool _closed = false;
  VoidCallback? onChanged;
  int get pending => _pending.length;
  Object? begin() {
    if (_closed || _pending.length >= 4) return null;
    final ticket = Object();
    _pending.add(ticket);
    return ticket;
  }

  void finish(Object? ticket) {
    if (ticket != null && _pending.remove(ticket) && !_closed)
      onChanged?.call();
  }

  void dispose() {
    _closed = true;
    _pending.clear();
    onChanged = null;
  }
}
