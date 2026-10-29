import 'dart:typed_data';
import 'dart:convert';
import 'package:student_platform/src/ui/authentication/screens/change_password_screen.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/schedule/lesson_details_screen.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/schedule/subject_diary/subject_diary.dart';
import 'package:student_platform/src/ui/schedule/subject_diary_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_selection_detail_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_options_editor_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/unified_task_details_screen.dart';
import 'package:student_platform/src/ui/info/subject_info_screen.dart';
import 'package:student_platform/src/ui/info/teacher_profile_screen.dart';
import 'package:student_platform/src/ui/info/entity_review_screen.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const login = String.fromEnvironment('E2E_LOGIN');
  const offering = String.fromEnvironment('E2E_OFFERING');
  if (!const bool.fromEnvironment('E2E_LIVE_APPROVED') ||
      !login.startsWith('e2e_') ||
      offering.isEmpty) throw StateError('Synthetic offering required');
  testWidgets('diary persistence and academic drilldown screens',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: const String.fromEnvironment('SUPABASE_URL'),
        anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'));
    final sb = Supabase.instance.client;
    await sb.auth.signInWithPassword(
        email: '$login@student.local',
        password: const String.fromEnvironment('E2E_PASSWORD'));
    final repo = SubjectDiaryRepositorySupabase();
    SubjectDiaryRepository.instance = repo;
    addTearDown(() async {
      await ChatFileAccess.clear();
      await Supabase.instance.dispose();
    });
    const args = SubjectDiaryArgs(
        subjectOfferingId: offering, subjectTitle: 'E2E subject');
    final today = DateTime.now();
    final entry = await repo.addText(
        subjectKey: 'E2E subject',
        date: today,
        text: 'E2E original note',
        args: args);
    try {
      expect(
          (await repo.listByArgs(args))
              .any((e) => e.id == entry.id && e.text == 'E2E original note'),
          isTrue);
      await repo.updateTextEntry(id: entry.id, newText: 'E2E edited note');
      expect(
          (await repo.listByArgs(args))
              .singleWhere((e) => e.id == entry.id)
              .text,
          'E2E edited note');
      final files = [
        SubjectDiaryPickedFile(
            name: 'e2e-diary.txt',
            mime: 'text/plain',
            bytes: Uint8List.fromList('E2E diary private'.codeUnits)),
        SubjectDiaryPickedFile(
            name: 'e2e-diary.png',
            mime: 'image/png',
            bytes: base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAANklEQVR4nO3RQQ0AAAjDwIFypCOhfPj1BIyk1GTyqV/X44EDf4BMhEyETIRMhEyETIRMhEwUsq7jAUAnCflgAAAAAElFTkSuQmCC'))
      ];
      await repo.addFilesPublic(
          subjectKey: 'E2E subject', date: today, files: files, args: args);
      await repo.addFilesPublic(
          subjectKey: 'E2E subject', date: today, files: files, args: args);
      final rows = await sb
          .from('subject_diary_files')
          .select('id,file_url,mime')
          .eq('entry_id', entry.id);
      expect(rows.length, 2, reason: 'retry must not duplicate attachment');
      final fileUrl = rows
          .singleWhere((r) => r['mime'] == 'text/plain')['file_url'] as String;
      expect(await ChatFileAccess.readBytes(fileUrl),
          'E2E diary private'.codeUnits);
      final peer = SupabaseClient(const String.fromEnvironment('SUPABASE_URL'),
          const String.fromEnvironment('SUPABASE_ANON_KEY'));
      await peer.auth.signInWithPassword(
          email:
              '${const String.fromEnvironment('E2E_PEER_LOGIN')}@student.local',
          password: const String.fromEnvironment('E2E_PASSWORD'));
      await expectLater(
          peer.functions.invoke('chat-file-access', body: {
            'action': 'resolve',
            'key': ChatFileAccess.keyFor(fileUrl)
          }),
          throwsA(isA<FunctionException>()));
      await peer.dispose();
      final teamRow = await sb
          .from('teams')
          .select()
          .eq('id', const String.fromEnvironment('E2E_SUBJECT_TEAM'))
          .single();
      final team = Team.fromJson({
        ...teamRow,
        'teacher': teamRow['teacher'] ?? '',
        'groupCode': teamRow['group_name'] ?? '',
        'icon': teamRow['icon'] ?? 'T'
      });
      final actions = ChatGroupActionsRepository();
      final topics = await actions.listTopicSelectionsForChat(
          const String.fromEnvironment('E2E_SUBJECT_CHAT'),
          cacheFirst: false);
      final collections = await sb
          .from('group_collections')
          .select('id')
          .eq('team_id', const String.fromEnvironment('E2E_TEAM'));
      final screens = <Widget>[
        const ChangePasswordScreen(),
        const MyChatsScreen(),
        LessonDetailsScreen(
            lesson: Lesson(
                id: 'E2E-model',
                date: today,
                week: 1,
                day: 'ПН',
                pairNum: 1,
                start: const TimeOfDay(hour: 9, minute: 0),
                end: const TimeOfDay(hour: 10, minute: 30),
                subjectRaw: 'E2E subject',
                subjectOfferingId: offering)),
        SubjectDiaryScreen(args: args),
        SubjectQuickNoteScreen(args: args, date: today),
        SubjectPhotoConspectScreen(
            subjectKey: 'E2E subject', args: args, date: today),
        SubjectInfoScreen(
            title: 'E2E subject',
            subjectOfferingId: offering,
            subjectId: team.subjectId),
        const TeacherProfileScreen(teacherName: 'E2E nonexistent teacher'),
        EntityReviewScreen(
            entityType: ReviewEntityType.subject,
            entityId: team.subjectId!,
            entityLabel: 'E2E subject'),
        for (final index in [0, 1, 2])
          TeamDetailsScreen(team: team, initialTabIndex: index),
        if (topics.isNotEmpty)
          TopicSelectionDetailScreen(
              chatId: const String.fromEnvironment('E2E_SUBJECT_CHAT'),
              selection: topics.first),
        if (topics.isNotEmpty)
          TopicOptionsEditorScreen(
              chatId: const String.fromEnvironment('E2E_SUBJECT_CHAT'),
              selectionId: topics.first.id,
              title: topics.first.title,
              selectionRowVersion: 1),
        if (topics.isNotEmpty)
          UnifiedTaskDetailsScreen(
              kind: 'topic_selection',
              entityId: topics.first.id,
              chatId: const String.fromEnvironment('E2E_SUBJECT_CHAT'),
              teamId: team.id),
        if (collections.isNotEmpty)
          UnifiedTaskDetailsScreen(
              kind: 'collection',
              entityId: collections.first['id'],
              chatId: const String.fromEnvironment('E2E_GROUP_CHAT'),
              teamId: const String.fromEnvironment('E2E_TEAM')),
      ];
      for (var index = 0; index < screens.length; index++) {
        final screen = screens[index];
        await tester.pumpWidget(MaterialApp(
            key: ValueKey(index),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('ru'), Locale('en')],
            locale: const Locale('ru'),
            home: screen));
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(screen.runtimeType), findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: '${screen.runtimeType} load');
        final scroll = find.byType(Scrollable);
        if (scroll.evaluate().isNotEmpty) {
          await tester.drag(scroll.first, const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 600));
        }
        expect(tester.takeException(), isNull,
            reason: '${screen.runtimeType} scroll');
        debugPrint('E2E academic screen: ${screen.runtimeType} index=$index');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));
      }
      await repo.removeFileFromEntry(entryId: entry.id, fileUrl: fileUrl);
      await expectLater(
          ChatFileAccess.readBytes(fileUrl), throwsA(isA<FunctionException>()));
      expect(
          (await sb
                  .from('subject_diary_files')
                  .select('id')
                  .eq('entry_id', entry.id))
              .length,
          1);
    } finally {
      await repo.deleteEntryCascade(entryId: entry.id);
    }
    expect((await repo.listByArgs(args)).any((e) => e.id == entry.id), isFalse);
  });
}
