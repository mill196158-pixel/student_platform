import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/collections/create_collection_screen.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:student_platform/src/services/chat_file_access.dart';

class FixturePicker extends FilePicker {
  FixturePicker(this.path);
  final String path;
  @override
  Future<FilePickerResult?> pickFiles(
          {String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Function(FilePickerStatus)? onFileLoading,
          bool allowCompression = true,
          int compressionQuality = 30,
          bool allowMultiple = false,
          bool withData = false,
          bool withReadStream = false,
          bool lockParentWindow = false,
          bool readSequential = false}) async =>
      FilePickerResult([
        PlatformFile(
            name: 'e2e-private.png',
            path: path,
            size: await File(path).length())
      ]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const login = String.fromEnvironment('E2E_LOGIN');
  if (!const bool.fromEnvironment('E2E_LIVE_APPROVED') ||
      !login.startsWith('e2e_')) throw StateError('Synthetic fixture required');
  testWidgets('collection publishes real selected file and private image opens',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: const String.fromEnvironment('SUPABASE_URL'),
        anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'));
    final sb = Supabase.instance.client;
    await sb.auth.signInWithPassword(
        email: '$login@student.local',
        password: const String.fromEnvironment('E2E_PASSWORD'));
    final path = '${(await getTemporaryDirectory()).path}/e2e-private.png';
    await File(path).writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAANklEQVR4nO3RQQ0AAAjDwIFypCOhfPj1BIyk1GTyqV/X44EDf4BMhEyETIRMhEyETIRMhEwUsq7jAUAnCflgAAAAAElFTkSuQmCC'));
    final old = FilePicker.platform;
    FilePicker.platform = FixturePicker(path);
    addTearDown(() async {
      FilePicker.platform = old;
      await ChatFileAccess.clear();
      await Supabase.instance.dispose();
    });
    final title = 'E2E collection ${DateTime.now().microsecondsSinceEpoch}';
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const CreateCollectionScreen())),
                    child: const Text('Open fixture'))))));
    await tester.tap(find.text('Open fixture'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, title);
    await tester.ensureVisible(find.text('Прикрепить файл или фото'));
    await tester.tap(find.text('Прикрепить файл или фото'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Создать сбор'));
    await tester.tap(find.text('Создать сбор'));
    for (var i = 0;
        i < 600 && find.byType(CreateCollectionScreen).evaluate().isNotEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(CreateCollectionScreen), findsNothing);
    final collections = await sb
        .from('group_collections')
        .select('id,card_message_id')
        .eq('title', title);
    expect(collections.length, 1);
    final files = await sb
        .from('chat_files')
        .select('id,file_url')
        .eq('message_id', collections.single['card_message_id']);
    expect(files.length, 1);
    final fileUrl = files.single['file_url'] as String;
    final bytes = await ChatFileAccess.readBytes(fileUrl);
    expect(bytes, isNotEmpty);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 32);
    frame.image.dispose();
    codec.dispose();
    Object? imageError;
    final stream = AuthorizedFileImageProvider(fileUrl)
        .resolve(const ImageConfiguration());
    final listener =
        ImageStreamListener((_, __) {}, onError: (Object e, StackTrace? s) {
      imageError = e;
    });
    stream.addListener(listener);
    await tester
        .pumpWidget(MaterialApp(home: FullscreenImage(imageUrl: fileUrl)));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    stream.removeListener(listener);
    expect(imageError, isNull);
    expect(find.text('Не удалось открыть изображение'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
