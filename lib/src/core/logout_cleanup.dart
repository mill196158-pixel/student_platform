enum LogoutCleanupResult {
  blockedBeforeSignOut,
  signedOut,
  signedOutCleanupIncomplete,
  signOutUnconfirmed,
  ownerChanged,
}

/// Try every in-memory fence even if a listener throws; failure still blocks
/// the durable barrier and sign-out.
void runLogoutMemoryFences(List<void Function()> fences) {
  var failed = false;
  for (final fence in fences) {
    try {
      fence();
    } catch (_) {
      failed = true;
    }
  }
  if (failed) throw StateError('Logout memory fence failed');
}

/// Try every cleanup even if one cache is unavailable. Authentication teardown
/// must not depend on disk caches, push registration, or realtime listeners.
Future<LogoutCleanupResult> runLogoutCleanup({
  /// Immediately invalidates current in-memory permits before the first await.
  void Function()? memoryFence,

  /// When configured, a durable access fence must succeed before any cleanup
  /// or authentication teardown. False/throw means logout was not performed.
  Future<bool> Function()? durableRevoke,

  /// Fail closed if another auth generation appears while logout is pending.
  bool Function()? isOwnerCurrent,

  /// After signOut, the old session may be null; a new session must not be
  /// cleared by the earlier logout.
  bool Function()? mayClearSession,
  required List<Future<void> Function()> cleanups,
  required Future<void> Function() signOut,
  required void Function() clearSession,
}) async {
  bool current() {
    try {
      return isOwnerCurrent?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  if (!current()) return LogoutCleanupResult.ownerChanged;
  try {
    memoryFence?.call();
  } catch (_) {
    return LogoutCleanupResult.blockedBeforeSignOut;
  }
  if (durableRevoke != null) {
    try {
      if (!await durableRevoke())
        return LogoutCleanupResult.blockedBeforeSignOut;
    } catch (_) {
      return LogoutCleanupResult.blockedBeforeSignOut;
    }
  }
  if (!current()) return LogoutCleanupResult.ownerChanged;
  var complete = true;
  var signOutConfirmed = false;
  for (final cleanup in cleanups) {
    if (!current()) return LogoutCleanupResult.ownerChanged;
    try {
      await cleanup();
    } catch (_) {
      complete = false;
    }
    if (!current()) return LogoutCleanupResult.ownerChanged;
  }
  if (!current()) return LogoutCleanupResult.ownerChanged;
  try {
    await signOut();
    signOutConfirmed = true;
  } catch (_) {
    // The server may have committed despite a lost response.
  }
  try {
    if (!(mayClearSession?.call() ?? true)) {
      return LogoutCleanupResult.ownerChanged;
    }
    clearSession();
  } catch (_) {
    complete = false;
  }
  if (!signOutConfirmed) return LogoutCleanupResult.signOutUnconfirmed;
  return complete
      ? LogoutCleanupResult.signedOut
      : LogoutCleanupResult.signedOutCleanupIncomplete;
}
