Future<T?> resolveForwardTargetForSession<T>(
    bool Function() isCurrent, Future<T> Function() resolve) async {
  if (!isCurrent()) return null;
  final value = await resolve();
  return isCurrent() ? value : null;
}
