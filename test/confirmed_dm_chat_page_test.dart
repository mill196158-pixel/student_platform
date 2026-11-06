import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
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

  test('RPC text and structured content stay distinct with verified file flags', () {
    Map<String, Object?> file(String id, Object? deleted) => {
      'id': id, 'chat_id': 'c', 'message_id': 'm', 'file_name': 'a.pdf',
      'file_key': 'chats/c/a.pdf', 'file_url': 'chats/c/a.pdf',
      'file_type': 'application/pdf', 'file_size': 7,
      if (deleted != 'missing') 'is_deleted': deleted,
      'deletion_verified': true,
    };
    Map<String, Object?> row() => {
      'id': 'm', 'chat_id': 'c', 'author_id': 'a',
      'text': '', 'content': jsonEncode({'from_chat_id': 'c', 'items': [
        {'id': 'source', 'author_id': 'a', 'author_name': 'Author',
         'created_at': '2026-01-01T00:00:00Z', 'text': 'hello',
         'attachments': [{'id': 'nested', 'url': 'chats/c/nested.pdf'}]}
      ]}),
      'type': 'forward', 'msg_type': 'forward',
      'at': '2026-01-01T00:00:00Z', 'created_at': '2026-01-01T00:00:00Z',
      'has_more': false,
      'attachments': [file('active', false), file('deleted', true),
        file('unknown', null), file('missing', 'missing')],
    };
    final message = DmApi.parseConfirmedMessagesPage([row()], 'c', limit: 50).messages.single;
    expect(message.forward?.items.single.id, 'source');
    expect(message.forward?.items.single.attachments.single.id, 'nested');
    expect(message.attachments!.map((f) => f.deletionVerified), [true, true, false, false]);
    expect(message.attachments!.map((f) => f.isDeleted), [false, true, false, false]);
    final restored = Message.fromJson(message.toJson());
    expect(restored.forward?.items.single.id, 'source');
    expect(restored.attachments!.map((f) => f.deletionVerified), [true, true, false, false]);
    final structuredCard = row()
      ..['content'] = jsonEncode({'card': 'collection',
        'collection_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'})
      ..['type'] = 'text';
    expect(DmApi.parseConfirmedMessagesPage([structuredCard], 'c', limit: 50)
        .messages.single.cardKind, 'collection');
    for (final bad in <Map<String, Object?>>[
      row()..['content'] = <String, Object>{},
      row()..['attachments'] = [file('bad', 'false')],
    ]) {
      expect(() => DmApi.parseConfirmedMessagesPage([bad], 'c', limit: 50),
          throwsFormatException);
    }
  });
}
