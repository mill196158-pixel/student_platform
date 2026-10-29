/// Try every cleanup even if one cache is unavailable. Authentication teardown
/// must not depend on disk caches, push registration, or realtime listeners.
Future<bool> runLogoutCleanup({
  required List<Future<void> Function()> cleanups,
  required Future<void> Function() signOut,
  required void Function() clearSession,
}) async {
  var complete = true;
  try {
    for (final cleanup in cleanups) {
      try {
        await cleanup();
      } catch (_) {
        complete = false;
      }
    }
  } finally {
    try {
      await signOut();
    } finally {
      clearSession();
    }
  }
  return complete;
}
