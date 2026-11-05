import 'dart:collection';

/// Small, process-local layout cache. It never stores image bytes or grants.
class ChatImageAspectCache {
  ChatImageAspectCache({this.maxEntries = 256});
  static final ChatImageAspectCache instance = ChatImageAspectCache();
  final int maxEntries;
  final _values = LinkedHashMap<(String, int, String), double>();

  double? read(
      {required String? user, required int epoch, required String url}) {
    if (user == null || user.isEmpty || url.isEmpty) return null;
    final key = (user, epoch, url);
    final value = _values.remove(key);
    if (value != null) _values[key] = value;
    return value;
  }

  void remember(
      {required String? user,
      required int epoch,
      required String url,
      required double ratio}) {
    if (user == null ||
        user.isEmpty ||
        url.isEmpty ||
        !ratio.isFinite ||
        ratio <= 0 ||
        maxEntries <= 0) return;
    final key = (user, epoch, url);
    _values.remove(key);
    _values[key] = ratio;
    while (_values.length > maxEntries) {
      _values.remove(_values.keys.first);
    }
  }
}
