import 'dart:async';
import 'package:flutter/foundation.dart';
import 'online_side_effect_barrier.dart';

/// Process-lifetime QA owner: a new shell cannot bypass an older shell's drain.
class QaOnlineSideEffectCoordinator extends ChangeNotifier {
  static final instance = QaOnlineSideEffectCoordinator();
  OnlineSideEffectBarrier? _barrier;
  bool _draining = false;
  bool _failed = false;
  bool get blocked => _draining || _failed;
  OnlineSideEffectBarrier? get barrier => _barrier;

  OnlineSideEffectBarrier? open(bool Function() ownerIsCurrent) {
    if (blocked) return null;
    return _barrier ??= OnlineSideEffectBarrier(ownerIsCurrent: ownerIsCurrent);
  }

  void close({required Duration timeout}) {
    final old = _barrier;
    if (old == null || _draining) return;
    _barrier = null;
    _draining = true;
    // The barrier runs teardown hooks synchronously before drain starts.
    unawaited(old.closeAndDrain(timeout: timeout).then((success) {
      _draining = false;
      _failed = !success;
      notifyListeners();
    }, onError: (Object _, StackTrace __) {
      _draining = false;
      _failed = true;
      notifyListeners();
    }));
    notifyListeners();
  }
}
