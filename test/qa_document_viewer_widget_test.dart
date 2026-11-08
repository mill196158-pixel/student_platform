import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('QA DOCX without confirmed source never exports or dispatches', (tester) async {
    debugDefaultTargetPlatformOverride=TargetPlatform.android;
    addTearDown(() { debugDefaultTargetPlatformOverride=null; });
    var pathCalls=0, nativeCalls=0;
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const path=MethodChannel('plugins.flutter.io/path_provider');
    const native=MethodChannel('student_platform/document_authority_qa');
    messenger.setMockMethodCallHandler(path,(_) async { pathCalls++; return null; });
    messenger.setMockMethodCallHandler(native,(_) async { nativeCalls++; return null; });
    addTearDown(() { messenger.setMockMethodCallHandler(path,null); messenger.setMockMethodCallHandler(native,null); });
    await tester.pumpWidget(const MaterialApp(home:FullscreenFileViewer(
      fileUrl:'https://example.invalid/test.docx',fileName:'test.docx',fileSize:12)));
    await tester.pump();
    await tester.tap(find.text('Открыть файл'));
    await tester.pump();
    expect(find.text('Не удалось открыть файл'),findsOneWidget);
    expect(pathCalls,0);
    expect(nativeCalls,0);
    debugDefaultTargetPlatformOverride=null;
  });
}
