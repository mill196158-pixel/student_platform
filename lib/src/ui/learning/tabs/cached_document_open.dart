/// Resolves a local path or URL, then checks the caller's session/file fence
/// immediately before handing it to an external application.
/// Callers must not start a fallback if that check became false while waiting.
Future<bool> tryOpenCachedDocument({
  required bool Function() isCurrent,
  required Future<String?> Function() cachedPath,
  required Future<bool> Function(String path) open,
}) async {
  try {
    if (!isCurrent()) return false;
    final path = await cachedPath();
    if (!isCurrent() || path == null || path.isEmpty) return false;
    return await open(path);
  } catch (_) {
    return false;
  }
}

/// Uses an authorized local copy first; named export and URL are fallbacks.
/// Each handoff is fenced again after its respective asynchronous lookup.
Future<bool> openDocumentWithFallback({
  required bool Function() isCurrent,
  required Future<String?> Function() cachedPath,
  required Future<bool> Function(String path) openCached,
  required Future<String?> Function() exportPath,
  required Future<bool> Function(String path) openExport,
  required Future<String?> Function() resolveUrl,
  required Future<bool> Function(String url) launchUrl,
}) async {
  if (await tryOpenCachedDocument(
      isCurrent: isCurrent, cachedPath: cachedPath, open: openCached)) {
    return true;
  }
  if (!isCurrent()) return false;
  if (await tryOpenCachedDocument(
      isCurrent: isCurrent, cachedPath: exportPath, open: openExport)) {
    return true;
  }
  if (!isCurrent()) return false;
  return tryOpenCachedDocument(
      isCurrent: isCurrent, cachedPath: resolveUrl, open: launchUrl);
}
