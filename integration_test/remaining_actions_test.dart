import 'package:student_platform/src/ui/learning/assignment_details_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_selection_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/info/entity_review_screen.dart';
import 'package:student_platform/src/ui/info/propose_vacancy_screen.dart';
import 'package:student_platform/src/ui/info/vacancy_submission_service.dart';
import 'package:student_platform/src/ui/chats/archive_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';

const base = String.fromEnvironment('SUPABASE_URL');
const key = String.fromEnvironment('SUPABASE_ANON_KEY');
const password = String.fromEnvironment('E2E_PASSWORD');
const login = String.fromEnvironment('E2E_LOGIN');
const run = String.fromEnvironment('E2E_RUN');
Future<void> tick(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> until(WidgetTester t, bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await tick(t, 1);
  }
  expect(condition(), isTrue);
}

Future<void> open(WidgetTester t, Widget screen) async {
  await t.pumpWidget(MaterialApp(
      key: UniqueKey(),
      home: Builder(
          builder: (ctx) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.of(ctx)
                      .push(MaterialPageRoute(builder: (_) => screen)),
                  child: const Text('Open fixture'))))));
  await t.tap(find.text('Open fixture'));
  await tick(t);
}

Future<void> fill(WidgetTester t, String label, String value) async {
  await t.drag(find.byType(ListView).first, const Offset(0, 2000));
  await tick(t);
  final f = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);
  await t.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
  await t.enterText(f, value);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('E2E_MAIN_APPROVED') ||
      !login.startsWith('e2e_') ||
      run.isEmpty) throw StateError('Approved fixture required');
  late SupabaseClient sb, peer, other, moderator;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: base, publishableKey: key);
    sb = Supabase.instance.client;
    peer = SupabaseClient(base, key);
    other = SupabaseClient(base, key);
    moderator = SupabaseClient(base, key);
    for (final pair in [
      (sb, login),
      (peer, const String.fromEnvironment('E2E_PEER_LOGIN')),
      (other, const String.fromEnvironment('E2E_OTHER_LOGIN')),
      (moderator, const String.fromEnvironment('E2E_MODERATOR_LOGIN'))
    ]) {
      await pair.$1.auth.signInWithPassword(
          email: '${pair.$2}@student.local', password: password);
      if (pair.$1.auth.currentUser?.userMetadata?['test_run'] != run)
        throw StateError('Fixture identity mismatch');
    }
  });
  tearDownAll(() async {
    await peer.dispose();
    await other.dispose();
    await moderator.dispose();
    await Supabase.instance.dispose();
  });
  if (!const bool.fromEnvironment('E2E_SKIP_REVIEW'))
    testWidgets(
        'review: score, submit, moderation, edit, aggregation and outsider isolation',
        (t) async {
      const subject = String.fromEnvironment('E2E_SUBJECT');
      await open(
          t,
          const EntityReviewScreen(
              entityType: ReviewEntityType.subject,
              entityId: subject,
              entityLabel: 'E2E review subject'));
      await until(t, () => find.byType(InputChip).evaluate().isNotEmpty);
      expect(find.byType(TextField), findsNothing,
          reason: 'text reviews disabled on server');
      await t.tap(find.byType(InputChip).first);
      await tick(t, 2);
      await t.ensureVisible(find.text('Отправить отзыв'));
      await t.tap(find.text('Отправить отзыв'));
      await tick(t, 40);
      var mine = await sb.rpc('get_my_entity_reviews', params: {'p_limit': 50})
          as List;
      final review = mine.singleWhere((r) => r['entity_id'] == subject);
      final id = review['id'] ?? review['review_id'];
      expect(id, isNotNull);
      final firstScore = review['tag_scores']['usefulness'] as int;
      expect(review['moderation_status'], 'pending');
      await expectLater(
          other.rpc('admin_moderate_review_v2',
              params: {'p_review_id': id, 'p_action': 'approve'}),
          throwsA(isA<PostgrestException>()));
      await moderator.rpc('admin_moderate_review_v2',
          params: {'p_review_id': id, 'p_action': 'approve'});
      final summary = await sb.rpc('get_entity_review_summary',
          params: {'p_entity_type': 'subject', 'p_entity_id': subject});
      expect(summary['active_count'], 1);
      final outsiderMine = await other
          .rpc('get_my_entity_reviews', params: {'p_limit': 50}) as List;
      expect(outsiderMine, isEmpty);
      await tick(t, 310);
      await t.tap(find.byType(InputChip).first);
      await tick(t, 2);
      await t.tap(find.text('Отправить отзыв'));
      await tick(t, 40);
      mine = await sb.rpc('get_my_entity_reviews', params: {'p_limit': 50})
          as List;
      expect(mine.where((r) => r['entity_id'] == subject).length, 1);
      expect(
          mine.singleWhere((r) => r['entity_id'] == subject)['tag_scores']
              ['usefulness'],
          firstScore % 5 + 1);
      expect(t.takeException(), isNull);
      debugPrint('ACTION PASS review submit/edit/moderation/aggregate');
    });
  if (!const bool.fromEnvironment('E2E_ACADEMIC_ONLY'))
    testWidgets(
        'vacancy: validation, submit once, clarification, edit, resubmit and moderation',
        (t) async {
      final scenario = '$run-${DateTime.now().microsecondsSinceEpoch}';
      await open(t, const ProposeVacancyScreen());
      await tick(t);
      final submit = find.text('Отправить на модерацию');
      await t.scrollUntilVisible(submit, 250,
          scrollable: find.byType(Scrollable).first);
      await t.tap(submit);
      await tick(t);
      expect(find.text('Заявка отправлена'), findsNothing);
      await fill(t, 'Название *', 'E2E vacancy $scenario');
      await fill(t, 'Краткое описание *', 'Synthetic vacancy action test');
      FocusManager.instance.primaryFocus?.unfocus();
      await tick(t);
      await t.scrollUntilVisible(submit, 250,
          scrollable: find.byType(Scrollable).first);
      await t.tap(submit);
      await t.tap(submit);
      await until(
          t, () => find.text('Заявка отправлена').evaluate().isNotEmpty);
      var rows = await sb
          .rpc('get_my_vacancy_submissions', params: {'p_limit': 50}) as List;
      final matches =
          rows.where((r) => r['title'] == 'E2E vacancy $scenario').toList();
      expect(matches.length, 1);
      var row = Map<String, dynamic>.from(matches.single);
      final id = row['id'];
      await expectLater(
          other.rpc('update_my_vacancy_draft', params: {
            'p_id': id,
            'p_patch': {'title': 'forbidden'},
            'p_expected_row_version': row['row_version']
          }),
          throwsA(isA<PostgrestException>()));
      await moderator.rpc('admin_moderate_vacancy', params: {
        'p_id': id,
        'p_action': 'request_clarification',
        'p_expected_row_version': row['row_version'],
        'p_reason': 'E2E add details'
      });
      await t.tap(find.text('Понятно'));
      await tick(t);
      rows = await sb.rpc('get_my_vacancy_submissions', params: {'p_limit': 50})
          as List;
      row = Map<String, dynamic>.from(rows.singleWhere((r) => r['id'] == id));
      expect(row['status'], 'draft');
      await open(
          t,
          ProposeVacancyScreen(
              existingSubmission: MyVacancySubmissionItem.tryParse(row)));
      await fill(t, 'Краткое описание *', 'Synthetic corrected vacancy');
      FocusManager.instance.primaryFocus?.unfocus();
      await tick(t);
      final resend = find.text('Сохранить и отправить снова');
      await t.scrollUntilVisible(resend, 250,
          scrollable: find.byType(Scrollable).first);
      await t.tap(resend);
      await until(
          t, () => find.text('Заявка отправлена снова').evaluate().isNotEmpty);
      rows = await sb.rpc('get_my_vacancy_submissions', params: {'p_limit': 50})
          as List;
      row = Map<String, dynamic>.from(rows.singleWhere((r) => r['id'] == id));
      expect(row['status'], 'submitted');
      expect(row['summary'], 'Synthetic corrected vacancy');
      await expectLater(
          sb.rpc('update_my_vacancy_draft', params: {
            'p_id': id,
            'p_patch': {'title': 'stale'},
            'p_expected_row_version': 1
          }),
          throwsA(isA<PostgrestException>()));
      row = Map<String, dynamic>.from(
          await moderator.rpc('admin_set_vacancy_audience', params: {
        'p_id': id,
        'p_mode': 'groups',
        'p_group_ids': [const String.fromEnvironment('E2E_GROUP')],
        'p_user_ids': [],
        'p_expected_row_version': row['row_version']
      }));
      var moderated = await moderator.rpc('admin_moderate_vacancy', params: {
        'p_id': id,
        'p_action': 'take_in_moderation',
        'p_expected_row_version': row['row_version']
      });
      moderated = await moderator.rpc('admin_moderate_vacancy', params: {
        'p_id': id,
        'p_action': 'approve',
        'p_expected_row_version': moderated['row_version']
      });
      expect(moderated['status'], 'approved');
      moderated = await moderator.rpc('admin_publish_vacancy', params: {
        'p_id': id,
        'p_expected_row_version': moderated['row_version']
      });
      expect(moderated['status'], 'published');
      expect(
          (await peer.rpc('get_my_vacancies') as List)
              .any((r) => r['id'] == id),
          isTrue);
      expect(
          (await other.rpc('get_my_vacancies') as List)
              .any((r) => r['id'] == id),
          isFalse);
      moderated = await moderator.rpc('admin_set_vacancy_lifecycle', params: {
        'p_id': id,
        'p_action': 'archive',
        'p_expected_row_version': moderated['row_version']
      });
      expect(moderated['status'], 'archived');
      expect(
          (await peer.rpc('get_my_vacancies') as List)
              .any((r) => r['id'] == id),
          isFalse);
      expect(
          await other
              .rpc('get_my_vacancy_submissions', params: {'p_limit': 50}),
          isEmpty);
      expect(t.takeException(), isNull);
      debugPrint('ACTION PASS vacancy submit/clarify/edit/resubmit/approve');
    });
  if (!const bool.fromEnvironment('E2E_ACADEMIC_ONLY'))
    testWidgets(
        'archive: open history, restore, hide only own copy, incoming restores dialog',
        (t) async {
      final chat = await sb.rpc('ensure_dm_chat',
          params: {'p_partner': peer.auth.currentUser!.id});
      await peer.rpc('send_message_in_chat_with_files', params: {
        'p_chat_id': chat,
        'p_text': 'E2E archive history',
        'p_file_ids': []
      });
      await sb.rpc('set_personal_chat_archived',
          params: {'p_chat_id': chat, 'p_archived': true});
      final team = Team(
          id: const String.fromEnvironment('E2E_SUBJECT_TEAM'),
          name: 'E2E',
          teacher: '',
          groupCode: '',
          icon: 'T');
      final cubit = TeamCubit(team);
      addTearDown(cubit.close);
      await open(
          t, BlocProvider.value(value: cubit, child: const ArchiveScreen()));
      await tick(t, 40);
      await t.tap(find.text('Личные'));
      await tick(t);
      final title = find.text('E2E Synthetic 1').first;
      await until(t, () => title.evaluate().isNotEmpty);
      await t.tap(title);
      await tick(t, 50);
      expect(find.text('E2E archive history'), findsWidgets);
      await t.pageBack();
      await tick(t);
      await t.longPress(title);
      await tick(t);
      await t.tap(find.text('Вернуть из архива'));
      await tick(t, 30);
      expect(
          (await sb.rpc('get_my_archived_chat_summaries') as List)
              .where((r) => r['chat_id'] == chat),
          isEmpty);
      await sb.rpc('set_personal_chat_archived',
          params: {'p_chat_id': chat, 'p_archived': true});
      await open(
          t, BlocProvider.value(value: cubit, child: const ArchiveScreen()));
      await tick(t, 30);
      await t.tap(find.text('Личные'));
      await tick(t);
      await t.longPress(title);
      await tick(t);
      await t.tap(find.text('Удалить у себя'));
      await tick(t);
      await t.tap(find.text('Удалить').last);
      await tick(t, 30);
      expect(
          (await sb.rpc('get_my_archived_chat_summaries') as List)
              .where((r) => r['chat_id'] == chat),
          isEmpty);
      final peerMessages = await peer
          .from('messages')
          .select('id')
          .eq('chat_id', chat)
          .eq('content', 'E2E archive history');
      expect(peerMessages, isNotEmpty);
      await peer.rpc('send_message_in_chat_with_files', params: {
        'p_chat_id': chat,
        'p_text': 'E2E incoming after hide',
        'p_file_ids': []
      });
      final summaries = await sb.rpc('get_my_chat_summaries') as List;
      expect(summaries.any((r) => r['chat_id'] == chat), isTrue);
      await expectLater(
          other.rpc('set_personal_chat_archived',
              params: {'p_chat_id': chat, 'p_archived': true}),
          throwsA(isA<PostgrestException>()));
      expect(t.takeException(), isNull);
      debugPrint('ACTION PASS archive history/restore/outsider');
    });

  testWidgets(
      'assignments: draft, vote, publish button, completion, edit and removal',
      (t) async {
    const teamId = String.fromEnvironment('E2E_SUBJECT_TEAM');
    final created = await peer.rpc('propose_assignment', params: {
      'p_team_id': teamId,
      'p_title': 'E2E assignment $run',
      'p_description': 'Synthetic draft',
      'p_link': '',
      'p_due': '',
      'p_attachments': []
    });
    final id = created['assignment_id'];
    expect(id, isNotNull);
    await peer.rpc('vote_assignment', params: {'p_assignment_id': id});
    await peer.rpc('vote_assignment', params: {'p_assignment_id': id});
    await expectLater(
        other.rpc('publish_assignment', params: {'p_assignment_id': id}),
        throwsA(isA<PostgrestException>()));
    final team =
        Team(id: teamId, name: 'E2E', teacher: '', groupCode: '', icon: 'T');
    final cubit = TeamCubit(team);
    addTearDown(cubit.close);
    await cubit.init();
    await until(
        t,
        () =>
            cubit.state.assignments.any((a) => a.id == id) &&
            !cubit.state.roleLoading);
    expect(cubit.state.assignments.singleWhere((a) => a.id == id).published,
        isFalse);
    await open(
        t,
        BlocProvider.value(
            value: cubit, child: AssignmentDetailsScreen(assignmentId: id)));
    await until(t, () => find.text('Опубликовать').evaluate().isNotEmpty);
    await t.tap(find.text('Опубликовать'));
    await tick(t, 40);
    expect(cubit.state.assignments.singleWhere((a) => a.id == id).published,
        isTrue);
    await open(
        t,
        BlocProvider.value(
            value: cubit, child: AssignmentDetailsScreen(assignmentId: id)));
    await t.tap(find.text('Отметить как выполнено'));
    await tick(t, 40);
    expect(cubit.isAssignmentDone(id), isTrue);
    final peerRows = await peer
        .rpc('get_team_assignments', params: {'p_team_id': teamId}) as List;
    expect(peerRows.singleWhere((r) => r['id'] == id)['completed_by_me'],
        isNot(true));
    await open(
        t,
        BlocProvider.value(
            value: cubit, child: AssignmentDetailsScreen(assignmentId: id)));
    await t.tap(find.text('Выполнено').last);
    await tick(t, 40);
    expect(cubit.isAssignmentDone(id), isFalse);
    await cubit.updateAssignment(id,
        title: 'E2E assignment edited $run', description: 'Updated');
    expect(cubit.state.assignments.singleWhere((a) => a.id == id).title,
        'E2E assignment edited $run');
    await expectLater(
        other.rpc('update_assignment', params: {
          'p_assignment_id': id,
          'p_title': 'forbidden',
          'p_description': '',
          'p_link': '',
          'p_due': '',
          'p_attachments': []
        }),
        throwsA(isA<PostgrestException>()));
    await expectLater(
        other.rpc('set_assignment_done',
            params: {'p_assignment_id': id, 'p_done': true}),
        throwsA(isA<PostgrestException>()));
    await expectLater(
        other.rpc('remove_assignment', params: {'p_assignment_id': id}),
        throwsA(isA<PostgrestException>()));
    await cubit.removeAssignment(id);
    expect(cubit.state.assignments.where((a) => a.id == id), isEmpty);
    expect(t.takeException(), isNull);
    debugPrint(
        'ACTION PASS assignment draft/vote/publish/complete/undo/edit/delete/ACL');
  });
  testWidgets(
      'topics: publish, edit, choose, capacity, cancel, release, close and delete',
      (t) async {
    final scenario = '$run-${DateTime.now().microsecondsSinceEpoch}';
    const chat = String.fromEnvironment('E2E_SUBJECT_CHAT');
    final repo = ChatGroupActionsRepository(client: sb);
    final peerRepo = ChatGroupActionsRepository(client: peer);
    final otherRepo = ChatGroupActionsRepository(client: other);
    await repo.publishTopicSelectionForChat(
        chatId: chat,
        title: 'E2E topics $scenario',
        options: const [
          TopicOptionDraft(title: 'E2E Topic A'),
          TopicOptionDraft(title: 'E2E Topic B', sortOrder: 1)
        ]);
    var selection =
        (await repo.listTopicSelectionsForChat(chat, cacheFirst: false))
            .singleWhere((s) => s.title == 'E2E topics $scenario');
    final id = selection.id;
    await repo.updateTopicSelectionBeforeActivity(
        selectionId: id, title: 'E2E topics edited $scenario');
    selection = (await repo.listTopicSelectionsForChat(chat, cacheFirst: false))
        .singleWhere((s) => s.id == id);
    expect(selection.title, 'E2E topics edited $scenario');
    var options = await repo.listTopicOptionsForSelection(id);
    final a = options.singleWhere((o) => o.title == 'E2E Topic A');
    final b = options.singleWhere((o) => o.title == 'E2E Topic B');
    await expectLater(otherRepo.pickTopic(selectionId: id, optionId: a.id),
        throwsA(isA<PostgrestException>()));
    await open(
        t,
        TopicSelectionDetailScreen(
            chatId: chat,
            selection: selection,
            repository: repo,
            canManage: true));
    await until(t, () => find.text('E2E Topic A').evaluate().isNotEmpty);
    await t.tap(find.text('E2E Topic A'));
    await tick(t);
    await t.tap(find.text('Выбрать').last);
    await tick(t, 30);
    options = await repo.listTopicOptionsForSelection(id);
    expect(options.singleWhere((o) => o.id == a.id).taken, 1);
    await expectLater(
        peerRepo.pickTopic(selectionId: id, optionId: a.id), throwsA(anything));
    await tick(t, 30);
    await t.ensureVisible(find.text('Освободить / изменить выбор'));
    await t.tap(find.text('Освободить / изменить выбор'));
    await tick(t, 30);
    expect(
        (await repo.listTopicOptionsForSelection(id))
            .singleWhere((o) => o.id == a.id)
            .taken,
        0);
    await peerRepo.pickTopic(selectionId: id, optionId: a.id);
    await repo.reassignTopicPick(
        selectionId: id, userId: peer.auth.currentUser!.id, optionId: b.id);
    expect(
        (await repo.listTopicOptionsForSelection(id))
            .singleWhere((o) => o.id == b.id)
            .taken,
        1);
    await repo.releaseTopicPick(
        selectionId: id, userId: peer.auth.currentUser!.id);
    expect(
        (await repo.listTopicOptionsForSelection(id))
            .singleWhere((o) => o.id == b.id)
            .taken,
        0);
    await repo.closeTopicSelection(selectionId: id);
    await expectLater(
        peerRepo.pickTopic(selectionId: id, optionId: a.id), throwsA(anything));
    await t.pumpWidget(const MaterialApp(home: Scaffold()));
    await tick(t);
    await expectLater(
        repo.deleteGroupAction(kind: 'topic_selection', entityId: id),
        throwsA(isA<PostgrestException>()));
    await repo.publishTopicSelectionForChat(
        chatId: chat,
        title: 'E2E delete $scenario',
        options: const [TopicOptionDraft(title: 'Disposable')]);
    final disposable =
        (await repo.listTopicSelectionsForChat(chat, cacheFirst: false))
            .singleWhere((s) => s.title == 'E2E delete $scenario');
    await repo.deleteGroupAction(
        kind: 'topic_selection', entityId: disposable.id);
    expect(
        (await repo.listTopicSelectionsForChat(chat, cacheFirst: false))
            .where((s) => s.id == disposable.id && s.status != 'cancelled'),
        isEmpty);
    expect(t.takeException(), isNull);
    debugPrint(
        'ACTION PASS topics publish/edit/UIchoose/capacity/cancel/reassign/release/close/delete/ACL');
  });
}
