import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/forward/sent_forward_sentinel.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';

void main() {
  test('only the confirmed operation marker is removed from a newer draft', () {
    LocalAttach file(String id, String path) => LocalAttach(
        localId: id, path: path, name: 'file', mimeType: 'test', size: 0,
        isImage: false);
    final draft = [
      file('durable-forward:old', '__FG__'),
      file('durable-forward:new', '__FG__'),
      file('legacy', '__FG__'),
      file('durable-forward:old', '/ordinary-file'),
    ];
    draft.removeWhere((item) => isTerminalForwardSentinel(item, {'old'}));
    expect(draft.map((item) => item.localId),
        ['durable-forward:new', 'legacy', 'durable-forward:old']);
  });
}
