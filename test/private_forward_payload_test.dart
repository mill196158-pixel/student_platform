import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';

void main() {
  const source = ForwardFileRef(
      id: 'old',
      url: 'https://old',
      name: 'file.txt',
      type: 'text/plain',
      size: 1);
  const copy = ForwardFileRef(
      id: 'new',
      url: 'https://new',
      name: 'file.txt',
      type: 'text/plain',
      size: 1);
  ForwardPayload payload(String text, List<ForwardFileRef> files) =>
      ForwardPayload(fromChatId: 'source', items: [
        ForwardItem(
            messageId: 'message',
            authorId: 'author',
            authorName: 'Name',
            at: DateTime.utc(2026),
            text: text,
            files: files)
      ]);
  test('nested forwards replace every source file reference', () {
    final nested = payload('text', [source]);
    final outer = payload(nested.encodeForText(), [source]);
    expect(outer.allFiles().length, 2);
    final updated = outer.withCopiedFiles({source.url: copy});
    expect(updated.allFiles().map((f) => f.id), ['new', 'new']);
    expect(updated.encodeForText(), isNot(contains('https://old')));
    expect(
        ForwardPayload.tryParse(updated.items.single.text)!.items.single.text,
        'text');
  });
  test('incomplete forward cannot silently omit attachment', () {
    expect(() => payload('', [source]).withCopiedFiles({}), throwsStateError);
  });
  test('malformed incoming forward is ignored without crashing', () {
    for (final text in ['__FG__:bad', '__FG__:[]', '__FG__:{"items":"bad"}']) {
      expect(ForwardPayload.tryParse(text), isNull);
    }
  });
}
