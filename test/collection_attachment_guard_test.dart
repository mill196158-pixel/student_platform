import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/collections/create_collection_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';

class TestPicker extends FilePicker {
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
      FilePickerResult(
          [PlatformFile(name: 'fixture.txt', size: 32, path: 'fixture.txt')]);
}

class RecordingRepository extends ChatGroupActionsRepository {
  RecordingRepository(SupabaseClient client) : super(client: client);
  int calls = 0;
  int uploads = 0;
  final keys = <String?>[];
  final attachments = <List<String>>[];
  final discarded = <String>[];
  @override
  Future<Map<String,String>> uploadCollectionFile(String path,String name) async {
    uploads++; return {'id':'fixture-id','key':'fixture-key'};
  }
  @override
  Future<void> discardCollectionUpload(String key) async { discarded.add(key); }
  @override
  Future<String> createCollection(
      {required String title,
      String description = '',
      String purpose = '',
      DateTime? deadlineAt,
      String amountMode = 'none',
      double? amountOptional,
      double? amountTotal,
      String instructions = '',
      String paymentDetails = '', String? clientKey, List<String> fileIds = const []}) async {
    calls++; keys.add(clientKey); attachments.add(fileIds);
    // Keep the form open, so test can inspect the attempted publication.
    throw StateError('test repository');
  }
}

void main() {
  testWidgets('collection retries atomic publication with same key and uploaded attachment',
      (tester) async {
    FilePicker? previous;
    try {
      previous = FilePicker.platform;
    } catch (_) {}
    FilePicker.platform = TestPicker();
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    addTearDown(() {
      if (previous != null) FilePicker.platform = previous!;
    });
    final repository = RecordingRepository(client);
    await tester.pumpWidget(
        MaterialApp(home: CreateCollectionScreen(repository: repository)));
    await tester.enterText(
        find.byType(TextFormField).first, 'Fixture collection');
    await tester.ensureVisible(find.text('Прикрепить файл или фото'));
    await tester.tap(find.text('Прикрепить файл или фото'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    ScaffoldMessenger.of(tester.element(find.byType(CreateCollectionScreen))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Создать сбор'));
    await tester.tap(find.text('Создать сбор'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    expect(repository.calls, 1);
    expect(repository.uploads, 1);
    expect(repository.attachments.single, ['fixture-id']);
    ScaffoldMessenger.of(tester.element(find.byType(CreateCollectionScreen))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Создать сбор'));
    await tester.tap(find.text('Создать сбор'));
    await tester.pumpAndSettle();
    expect(repository.calls, 2);
    expect(repository.uploads, 1);
    expect(repository.keys[0], isNotNull);
    expect(repository.keys[1], repository.keys[0]);
    expect(repository.attachments[1], ['fixture-id']);
    await tester.ensureVisible(find.byTooltip('Удалить'));
    await tester.tap(find.byTooltip('Удалить'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    ScaffoldMessenger.of(tester.element(find.byType(CreateCollectionScreen))).clearSnackBars();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Создать сбор'));
    await tester.tap(find.text('Создать сбор'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    expect(repository.calls, 3);
    expect(repository.attachments.last, isEmpty);
    expect(repository.discarded, ['fixture-key']);
  });
}
