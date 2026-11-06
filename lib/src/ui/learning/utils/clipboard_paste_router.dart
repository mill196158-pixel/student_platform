/// Routes clipboard paste only while the captured session and target are
/// current. Rich files take priority over text/URI coercion from the platform.
Future<void> routeClipboardPaste<T>({
  required bool Function() isCurrent,
  required Future<T?> Function() readFile,
  required Future<String?> Function() readText,
  required Future<void> Function(T) attachFile,
  required void Function(String) insertText,
  required void Function() onEmpty,
}) async {
  if (!isCurrent()) return;
  final file = await readFile();
  if (!isCurrent()) return;
  if (file != null) {
    await attachFile(file);
    return;
  }
  final text = await readText();
  if (!isCurrent()) return;
  if (text == null || text.isEmpty) {
    onEmpty();
    return;
  }
  insertText(text);
}
