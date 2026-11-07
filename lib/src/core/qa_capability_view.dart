import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'online_side_effect_barrier.dart';
import 'qa_online_side_effect_coordinator.dart';
import 'session_capabilities.dart';

/// QA-only shell coordinator. It does not issue authorization.
class QaCapabilityView extends StatefulWidget {
  const QaCapabilityView(
      {super.key,
      required this.capabilities,
      required this.onlineBuilder,
      required this.cachedBuilder,
      required this.blockedBuilder,
      this.drainTimeout = const Duration(seconds: 10),
      this.coordinator,
      this.retainOnlineForRotation = false});
  final SessionCapabilities capabilities;
  final Widget Function(BuildContext, OnlineSideEffectBarrier) onlineBuilder;
  final WidgetBuilder cachedBuilder;
  final WidgetBuilder blockedBuilder;
  final Duration drainTimeout;
  final QaOnlineSideEffectCoordinator? coordinator;
  /// Experimental: retains State while blocked; does not stop child work.
  final bool retainOnlineForRotation;
  @override
  State<QaCapabilityView> createState() => _QaCapabilityViewState();
}

class _QaCapabilityViewState extends State<QaCapabilityView> {
  late QaOnlineSideEffectCoordinator _coordinator;
  Widget? _retainedOnline;
  bool _refreshScheduled = false;

  Widget _retained({required bool showOnline, required Widget fallback}) =>
      Stack(fit: StackFit.expand, children: [
        Offstage(offstage: !showOnline,
          child: _retainedOnline ?? const SizedBox.shrink()),
        if (!showOnline) fallback,
      ]);

  @override
  void initState() {
    super.initState();
    _coordinator = widget.coordinator ?? QaOnlineSideEffectCoordinator.instance;
    _coordinator.addListener(_coordinatorChanged);
    widget.capabilities.addListener(_changed);
  }

  void _coordinatorChanged() {
    if (!mounted || _refreshScheduled) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
      return;
    }
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _changed() {
    final old = _coordinator.barrier;
    if (old != null && !old.isOpen) {
      _coordinator.close(timeout: widget.drainTimeout);
    }
    _coordinatorChanged();
  }

  @override
  void didUpdateWidget(covariant QaCapabilityView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.capabilities, widget.capabilities)) {
      oldWidget.capabilities.removeListener(_changed);
      _coordinator.close(timeout: widget.drainTimeout);
      widget.capabilities.addListener(_changed);
    }
    // A mounted shell keeps its original coordinator; swapping it could let a
    // new owner bypass a drain still running in the previous coordinator.
  }

  @override
  void dispose() {
    widget.capabilities.removeListener(_changed);
    _coordinator.removeListener(_coordinatorChanged);
    _coordinator.close(timeout: widget.drainTimeout);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_coordinator.blocked) return widget.retainOnlineForRotation
        ? _retained(showOnline: false, fallback: widget.blockedBuilder(context))
        : widget.blockedBuilder(context);
    final caps = widget.capabilities;
    switch (caps.mode) {
      case SessionCapabilityMode.online:
        final permit = caps.capture(SessionCapability.networkRead);
        if (permit == null ||
            !caps.permits(permit, SessionCapability.networkRead)) {
          return widget.retainOnlineForRotation
              ? _retained(showOnline: false, fallback: widget.blockedBuilder(context))
              : widget.blockedBuilder(context);
        }
        final barrier = _coordinator.open(() =>
            caps.mode == SessionCapabilityMode.online &&
            caps.permits(permit, SessionCapability.networkRead));
        if (barrier == null || !barrier.isOpen) {
          return widget.retainOnlineForRotation
              ? _retained(showOnline: false, fallback: widget.blockedBuilder(context))
              : widget.blockedBuilder(context);
        }
        final online = widget.onlineBuilder(context, barrier);
        if (!widget.retainOnlineForRotation) return online;
        _retainedOnline = online;
        return _retained(showOnline: true, fallback: const SizedBox.shrink());
      case SessionCapabilityMode.cacheOnly:
        final permit = caps.capture(SessionCapability.cachedRead);
        return permit != null &&
                caps.permits(permit, SessionCapability.cachedRead)
            ? widget.cachedBuilder(context)
            : widget.blockedBuilder(context);
      case SessionCapabilityMode.blocked:
        return widget.retainOnlineForRotation
            ? _retained(showOnline: false, fallback: widget.blockedBuilder(context))
            : widget.blockedBuilder(context);
    }
  }
}
