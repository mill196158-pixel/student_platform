import 'package:flutter/material.dart';

import 'auth_session_scope.dart';
import 'qa_rotation_receipt.dart';
import 'session_capabilities.dart';

/// Experimental visual/input guard. It does not stop or drain route work.
class QaRotationNavigationGuard extends StatefulWidget {
  const QaRotationNavigationGuard({super.key, required this.scope,
    required this.capabilities, required this.receipt, required this.child,
    this.refreshStarts, this.hasPendingRefresh});
  final AuthSessionScope scope;
  final SessionCapabilities capabilities;
  final QaRotationReceipt receipt;
  final Listenable? refreshStarts;
  final bool Function()? hasPendingRefresh;
  final Widget child;

  /// Receipt is present only inside the explicitly enabled QA guard.
  static QaRotationReceipt? maybeRead(BuildContext context) => context
      .getInheritedWidgetOfExactType<_QaRotationReceiptProvider>()?.receipt;

  @override
  State<QaRotationNavigationGuard> createState() => _QaRotationNavigationGuardState();
}

class _QaRotationNavigationGuardState extends State<QaRotationNavigationGuard> {
  AuthOperationScope? _owner;
  CapabilityPermit? _permit;
  bool _locked = false;
  bool _refreshPending = false;
  bool _ambiguousRefresh = false;

  @override
  void initState() {
    super.initState();
    widget.scope.addListener(_changed);
    widget.capabilities.addListener(_changed);
    widget.receipt.addListener(_changed);
    widget.refreshStarts?.addListener(_refreshStarted);
    _evaluate();
  }

  void _evaluate() {
    final caps = widget.capabilities;
    final owner = _owner;
    if (owner == null) {
      final capability = caps.mode == SessionCapabilityMode.online
          ? SessionCapability.networkRead : SessionCapability.cachedRead;
      final permit = caps.capture(capability);
      if (permit != null && caps.permits(permit, capability)) {
        _owner = widget.scope.capture();
        _permit = permit;
        try {
          _refreshPending = widget.hasPendingRefresh?.call() ?? false;
        } catch (_) {
          _refreshPending = true;
        }
        if (_refreshPending) _locked = true;
      }
      return;
    }
    final permit = _permit;
    if (!widget.scope.isCurrent(owner) || permit == null ||
        !caps.permits(permit, permit.capability)) {
      _locked = true;
    }
    if (_locked && !_ambiguousRefresh &&
        widget.receipt.permitsResume(owner, widget.scope, caps)) {
      _owner = widget.scope.capture();
      _permit = caps.capture(SessionCapability.networkRead);
      _locked = _owner == null || _permit == null;
      if (!_locked) _refreshPending = false;
    }
  }

  void _changed() {
    final wasLocked = _locked;
    _evaluate();
    if (!wasLocked && _locked) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (mounted) setState(() {});
  }

  void _refreshStarted() {
    if (_owner == null) return;
    if (_refreshPending) _ambiguousRefresh = true;
    _refreshPending = true;
    _locked = true;
    widget.receipt.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant QaRotationNavigationGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.scope, widget.scope) ||
        !identical(oldWidget.capabilities, widget.capabilities) ||
        !identical(oldWidget.receipt, widget.receipt) ||
        !identical(oldWidget.refreshStarts, widget.refreshStarts)) {
      oldWidget.scope.removeListener(_changed);
      oldWidget.capabilities.removeListener(_changed);
      oldWidget.receipt.removeListener(_changed);
      oldWidget.refreshStarts?.removeListener(_refreshStarted);
      if (_owner != null) _locked = true;
      widget.scope.addListener(_changed);
      widget.capabilities.addListener(_changed);
      widget.receipt.addListener(_changed);
      widget.refreshStarts?.addListener(_refreshStarted);
    }
  }

  @override
  void dispose() {
    widget.scope.removeListener(_changed);
    widget.capabilities.removeListener(_changed);
    widget.receipt.removeListener(_changed);
    widget.refreshStarts?.removeListener(_refreshStarted);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _evaluate();
    return _QaRotationReceiptProvider(receipt: widget.receipt, child: Stack(fit: StackFit.expand, children: [
      Offstage(offstage: _locked, child: ExcludeFocus(excluding: _locked,
        child: widget.child)),
      if (_locked) const ColoredBox(color: Colors.white,
        child: Center(child: Text('Сессия проверяется.'))),
    ]));
  }
}

class _QaRotationReceiptProvider extends InheritedWidget {
  const _QaRotationReceiptProvider({required this.receipt, required super.child});
  final QaRotationReceipt receipt;
  @override
  bool updateShouldNotify(_QaRotationReceiptProvider oldWidget) =>
      !identical(receipt, oldWidget.receipt);
}
