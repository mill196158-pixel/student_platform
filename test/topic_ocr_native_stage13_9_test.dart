import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/composite_topic_ocr_adapter.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_image_rotate.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_models.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_normalizer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_parser.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_list_review_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/tesseract_topic_ocr_impl.dart';

class _RecordingChannel {
  _RecordingChannel({
    this.available = true,
    this.recognizeText = '1. Тема A\n2. Topic B',
    this.throwMissingPlugin = false,
    this.throwOnRecognize = false,
  });

  bool available;
  String recognizeText;
  bool throwMissingPlugin;
  bool throwOnRecognize;
  int recognizeCalls = 0;
  int availableCalls = 0;

  Future<dynamic> handler(MethodCall call) async {
    switch (call.method) {
      case 'isAvailable':
        availableCalls += 1;
        if (throwMissingPlugin) {
          throw MissingPluginException('no channel');
        }
        return available;
      case 'recognize':
        recognizeCalls += 1;
        if (throwMissingPlugin) {
          throw MissingPluginException('no channel');
        }
        if (throwOnRecognize) {
          throw PlatformException(
            code: 'unsupported_os',
            message:
                'Распознавание кириллицы с фото доступно на iOS 16 и новее. '
                'Введите темы вручную или выберите Excel/Word/PDF.',
          );
        }
        final args = Map<String, dynamic>.from(call.arguments as Map);
        expect(args['path'], isA<String>());
        expect(
          args['languages'],
          anyOf('rus+eng', 'ru-RU,en-US'),
        );
        return recognizeText;
      default:
        throw MissingPluginException(call.method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native topic OCR channel contract', () {
    test('missing channel yields clear FormatException, not crash', () async {
      const channel = MethodChannel('student_platform/topic_ocr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      final recording = _RecordingChannel(throwMissingPlugin: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, recording.handler);

      final adapter = TesseractTopicOcrAdapter(
        channel: channel,
        supportsNativePlatform: true,
      );

      expect(await adapter.isAvailable(), isFalse);
      await expectLater(
        adapter.recognize(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('вручную'),
          ),
        ),
      );
    });

    test('unsupported OS maps PlatformException to Russian guidance', () async {
      const channel = MethodChannel('student_platform/topic_ocr');
      final recording = _RecordingChannel(
        available: true,
        throwOnRecognize: true,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, recording.handler);

      final adapter = TesseractTopicOcrAdapter(
        channel: channel,
        supportsNativePlatform: true,
      );
      await expectLater(
        adapter.recognize(Uint8List.fromList([9, 9, 9])),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('iOS 16'),
          ),
        ),
      );
    });

    test('recognize requests rus+eng or ru-RU and returns bilingual list',
        () async {
      const channel = MethodChannel('student_platform/topic_ocr');
      final recording = _RecordingChannel(
        recognizeText: '1. Введение в SQL\n2. Graph algorithms\n3. Индексы',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, recording.handler);

      final adapter = TesseractTopicOcrAdapter(
        channel: channel,
        supportsNativePlatform: true,
      );
      expect(await adapter.isAvailable(), isTrue);

      final text = await adapter.recognize(Uint8List.fromList([7, 7, 7]));
      expect(recording.recognizeCalls, 1);
      expect(text, contains('Введение в SQL'));
      expect(text, contains('Graph algorithms'));

      final parsed = await TopicListParser(ocrAdapter: adapter).parseBytes(
        bytes: Uint8List.fromList([7, 7, 7]),
        sourceName: 'scan.png',
      );
      expect(parsed.topics.map((t) => t.title), [
        'Введение в SQL',
        'Graph algorithms',
        'Индексы',
      ]);
    });

    test('oversized image rejected before native call', () async {
      const channel = MethodChannel('student_platform/topic_ocr');
      final recording = _RecordingChannel();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, recording.handler);

      final adapter = TesseractTopicOcrAdapter(
        channel: channel,
        supportsNativePlatform: true,
      );
      final huge = Uint8List(topicListMaxFileBytes + 1);
      await expectLater(
        adapter.recognize(huge),
        throwsA(isA<FormatException>()),
      );
      expect(recording.recognizeCalls, 0);
    });
  });

  group('OCR review smoke helpers', () {
    test('re-parse + normalize does not create duplicate topics', () {
      final controller = TopicListReviewController(
        initial: const [
          TopicDraft(title: 'Тема A'),
          TopicDraft(title: 'Тема B'),
        ],
      );
      controller.applyParseResult(
        TopicParseResult(
          sourceName: 'scan.png',
          kind: TopicParseSourceKind.image,
          topics: normalizeTopicLines([
            '1. Тема A',
            '2. Тема B',
            '1. Тема A',
          ]),
        ),
      );
      controller.dedupe();
      expect(controller.topics.map((t) => t.title), ['Тема A', 'Тема B']);
    });

    test('composite prefers Cyrillic bilingual fallback', () async {
      final adapter = CompositeTopicOcrAdapter(
        primary: const FakeTopicOcrAdapter('1. Topic only'),
        cyrillicFallback: const FakeTopicOcrAdapter(
          '1. Тема на русском\n2. Topic in English\n3. Ещё тема',
        ),
      );
      final text = await adapter.recognize(Uint8List.fromList([1]));
      expect(text, contains('Тема на русском'));
      expect(text, contains('Topic in English'));
    });

    test('rotate helper no-ops for 0 degrees and keeps bytes', () async {
      final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final rotated = await rotateTopicImageBytes(bytes: bytes, degrees: 0);
      expect(rotated, bytes);
    });
  });
}
