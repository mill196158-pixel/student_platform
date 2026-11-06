/// Checks the raw get_chat_messages_page RPC contract before permissive model
/// decoders can turn malformed values into plausible empty messages.
void validateConfirmedChatRow(Map<String, dynamic> row, String chatId) {
  final id = row['id'];
  bool nullableString(Object? v) => v == null || v is String;
  if (id is! String ||
      id.isEmpty ||
      row['chat_id'] != chatId ||
      !row.containsKey('author_id') ||
      !nullableString(row['author_id']) ||
      row['text'] is! String ||
      row['type'] is! String ||
      (row['type'] as String).isEmpty ||
      DateTime.tryParse((row['at'] ?? row['created_at'] ?? '').toString()) ==
          null ||
      row['has_more'] is! bool ||
      row['attachments'] is! List) {
    throw const FormatException('Invalid confirmed chat row');
  }
  for (final item in row['attachments'] as List) {
    if (item is! Map ||
        item.keys.any((k) => k is! String) ||
        item['id'] is! String ||
        (item['id'] as String).isEmpty ||
        item['chat_id'] != chatId ||
        item['message_id'] != id ||
        !nullableString(item['file_name']) ||
        !nullableString(item['file_key']) ||
        !nullableString(item['file_url']) ||
        !nullableString(item['file_type']) ||
        (item['file_size'] != null &&
            (item['file_size'] is! num || (item['file_size'] as num) < 0))) {
      throw const FormatException('Invalid confirmed chat attachment');
    }
  }
  final reactions = row['reactions'];
  if (reactions != null &&
      (reactions is! Map ||
          reactions.entries.any((e) =>
              e.key is! String || e.value is! int || (e.value as int) < 0))) {
    throw const FormatException('Invalid confirmed reactions');
  }
  final mine = row['user_reactions'];
  if (mine != null && (mine is! List || mine.any((e) => e is! String))) {
    throw const FormatException('Invalid confirmed reactions');
  }
}
