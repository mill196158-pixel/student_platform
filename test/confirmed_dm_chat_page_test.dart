import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

void main() {
  test('only a valid raw RPC page can become a confirmed DM snapshot', () {
    Map<String, Object?> row() => {
          'id': 'm',
          'chat_id': 'c',
          'at': '2026-01-01T00:00:00Z',
          'has_more': false,
          'author_id': null,
          'text': '',
          'type': 'text',
          'attachments': <Object>[]
        };
    final valid = DmApi.parseConfirmedMessagesPage([row()], 'c', limit: 50);
    expect(valid.source, ConfirmedDmSource.serverRpc);
    expect(valid.messages.single.id, 'm');
    expect(valid.hasMore, isFalse);
    for (final bad in <Object?>[
      null,
      {},
      [row()..['chat_id'] = 'other'],
      [row()..remove('chat_id')],
      [row()..['at'] = 'bad'],
      [row()..remove('id')],
      [row(), row()],
      [row()..['has_more'] = 'false'],
      [row()..remove('author_id')],
      [row()..remove('text')],
      [row()..['type'] = 4],
      [row()..['attachments'] = 'broken'],
      [
        row()..['attachments'] = [null]
      ],
      [
        row()
          ..['attachments'] = [
            {'id': 'f', 'chat_id': 'c', 'message_id': 'different'}
          ]
      ],
    ]) {
      expect(() => DmApi.parseConfirmedMessagesPage(bad, 'c', limit: 50),
          throwsFormatException);
    }
    final card = row()
      ..['text'] =
          '{"card":"collection","collection_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}';
    final mapped = DmApi.parseConfirmedMessagesPage([card], 'c', limit: 50)
        .messages
        .single;
    expect(mapped.cardKind, 'collection');
    expect(mapped.cardEntityId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    expect(mapped.text, isNot(contains('"card"')));
    final restored = Message.fromJson(mapped.toJson());
    expect(restored.cardKind, 'collection');
    expect(restored.cardEntityId, mapped.cardEntityId);
    final full = List.generate(
        50,
        (i) => row()
          ..['id'] = '$i'
          ..['has_more'] = true);
    expect(
        DmApi.parseConfirmedMessagesPage(full, 'c', limit: 50).hasMore, isTrue);
  });
}
