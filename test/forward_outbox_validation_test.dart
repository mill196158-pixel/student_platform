import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('invalid queued forwards remain intact', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (final raw in [
      '{bad', '[]', '{}', '{"text":42}',
      jsonEncode({'text': '__FG__:{broken', 'files': []}),
    ]) {
      await prefs.setString('entry', raw);
      expect(await ForwardOutbox.readAndConsume(prefs, 'entry', () => true), isNull);
      expect(prefs.getString('entry'), raw);
    }
  });
  test('legacy text and valid forwards are consumed', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    for (final text in ['hello', '__FG__:{"from":"chat","items":[]}']) {
      await prefs.setString('entry', jsonEncode({'text': text, 'files': ['file']}));
      final result = await ForwardOutbox.readAndConsume(prefs, 'entry', () => true);
      expect(result?.text, text);
      expect(result?.fileUrls, ['file']);
      expect(prefs.containsKey('entry'), isFalse);
    }
  });
  test('scope change and missing record do not consume data', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(await ForwardOutbox.readAndConsume(prefs, 'entry', () => true), isNull);
    await prefs.setString('entry', '{"text":"hello"}');
    var checks = 0;
    expect(await ForwardOutbox.readAndConsume(prefs, 'entry', () => ++checks == 1), isNull);
    expect(prefs.containsKey('entry'), isTrue);
  });
}
