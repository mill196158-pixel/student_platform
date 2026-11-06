import 'package:flutter/foundation.dart';

/// Process-local proof for the exact SDK error already covered by admission.
/// This does not issue access: its predicate must also validate the owner,
/// capability, transport gate and durable policy decision.
class OfflineAuthErrorReceipt extends ChangeNotifier {
  OfflineAuthErrorReceipt._();
  static final instance = OfflineAuthErrorReceipt._();
  bool _strict = false;
  bool get strict => _strict;
  void activateStrict() {
    clear();
    _strict = true;
  }
  Object? _error;
  bool Function()? _valid;
  List<Listenable> _sources = [];

  bool _isValid() {
    try {
      return _valid?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  bool accepts(Object error) {
    if (!identical(error, _error)) return false;
    if (_isValid()) return true;
    clear();
    return false;
  }

  void install(Object error, bool Function() valid, List<Listenable> sources) {
    clear();
    _error = error;
    _valid = valid;
    if (!_isValid()) {
      clear();
      return;
    }
    try {
      for (final source in sources) {
        source.addListener(_check);
        _sources.add(source);
      }
    } catch (_) {
      clear();
      return;
    }
    if (!_isValid()) clear();
  }

  void _check() {
    if (!_isValid()) clear();
  }

  void clear() {
    final hadReceipt = _error != null;
    for (final source in _sources) {
      try {
        source.removeListener(_check);
      } catch (_) {
        // Continue revoking even if a source is already unavailable.
      }
    }
    _sources = [];
    _error = null;
    _valid = null;
    if (hadReceipt) notifyListeners();
  }
}
