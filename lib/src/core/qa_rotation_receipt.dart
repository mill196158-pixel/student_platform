import 'package:flutter/foundation.dart';

import 'auth_session_scope.dart';
import 'session_capabilities.dart';

/// Ephemeral evidence from the QA policy observer. It is not an authorization
/// permit and does not establish that untracked screen work has drained.
class QaRotationReceipt extends ChangeNotifier {
  AuthOperationScope? _previous;
  AuthOperationScope? _current;
  SessionCapabilities? _capabilities;
  CapabilityPermit? _permit;

  void clear() {
    _previous = null;
    _current = null;
    _capabilities = null;
    _permit = null;
    notifyListeners();
  }

  void record(AuthOperationScope previous, AuthOperationScope current,
      SessionCapabilities capabilities) {
    _previous = previous;
    _current = current;
    _capabilities = capabilities;
    _permit = capabilities.capture(SessionCapability.networkRead);
    notifyListeners();
  }

  bool permitsResume(AuthOperationScope previous, AuthSessionScope scope,
      SessionCapabilities capabilities) {
    final current = _current, permit = _permit;
    return _previous == previous && current != null && permit != null &&
        identical(_capabilities, capabilities) && scope.isCurrent(current) &&
        capabilities.mode == SessionCapabilityMode.online &&
        capabilities.permits(permit, SessionCapability.networkRead);
  }
}
