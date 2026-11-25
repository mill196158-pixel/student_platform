import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

class _Jobs {
  _Jobs(this.tester, this.client);
  final WidgetTester tester;
  final SupabaseClient client;

  Future<void> until(Finder finder) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finder, findsWidgets);
  }

  Future<void> animate() async {
    for (var n = 0; n < 5; n++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> tap(String text) async {
    final target = find.text(text);
    await until(target);
    await tester.ensureVisible(target.first);
    await animate();
    await tester.tap(target.hitTestable().first);
    await animate();
  }

  Finder field(String label) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == label);

  Future<void> fill(String label, String value) async {
    final target = field(label);
    await until(target);
    await tester.ensureVisible(target);
    await animate();
    await tester.enterText(target, value);
    await animate();
  }

  String value(String label) =>
      tester.widget<TextField>(field(label)).controller!.text;

  Future<void> board() async {
    await tester.pumpWidget(MaterialApp(
        key: UniqueKey(), home: const InfoScreen(initialSectionName: 'jobs')));
    await until(find.text('Предложить'));
  }

  Future<List<Map<String, dynamic>>> rows() async =>
      List<Map<String, dynamic>>.from(
          await client.rpc('get_my_vacancy_submissions'));

  Future<Map<String, dynamic>> row(String title) async =>
      (await rows()).singleWhere((row) => row['title'] == title);

  Future<void> openDraft(String title) async {
    await tap('Мои заявки');
    await tap(title);
    await until(find.text('Исправить вакансию'));
  }

  Future<void> accepted(String title) async {
    await until(find.text(title));
    expect(find.textContaining('Демо-режим'), findsNothing);
    await tap('Понятно');
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['STUDENT_VACANCY_LOCAL'];
  if (fixture == null) {
    test('requires isolated local vacancy fixture', () {}, skip: true);
    return;
  }
  late SupabaseClient client;
  late LocalSchemaHttpClient transport;
  late List<dynamic> accounts;
  Future<void> signIn(int index) async {
    if (client.auth.currentSession != null) await client.auth.signOut();
    final account = accounts[index];
    final auth = await client.auth.signInWithPassword(
        email: account['email'] as String,
        password: account['password'] as String);
    expect(auth.user?.id, account['student']);
  }

  setUpAll(() async {
    final data = jsonDecode(fixture) as Map<String, dynamic>;
    final schema = data['schema'] as String;
    expect(schema, matches(RegExp(r'^e2e_vacancy_[0-9a-f]{12}$')));
    expect(SupabaseConfig.url, localSupabaseUrl);
    accounts = data['accounts'] as List;
    expect(accounts.map((a) => a['email']),
        ['$schema@student.local', '${schema}1@student.local']);
    SharedPreferences.setMockInitialValues({});
    transport = LocalSchemaHttpClient(data['restPort'] as int);
    await Supabase.initialize(
        url: localSupabaseUrl,
        publishableKey: data['anon'] as String,
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage()),
        postgrestOptions: PostgrestClientOptions(schema: schema));
    client = Supabase.instance.client;
  });
  tearDownAll(() async {
    await client.auth.signOut();
    await Supabase.instance.dispose();
    transport.close();
  });

  void journey(String name, Future<void> Function(_Jobs) act) {
    testWidgets(name, (tester) async {
      await binding.setSurfaceSize(const Size(390, 740));
      tester.testTextInput.register();
      await signIn(0);
      final jobs = _Jobs(tester, client);
      try {
        await jobs.board();
        await act(jobs);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await binding.setSurfaceSize(null);
      }
    });
  }

  journey(
      'requirements survive moderator clarification with no long description',
      (j) async {
    await j.tap('Предложить');
    await j.fill('Название *', 'Blueprint placement');
    await j.fill('Краткое описание *', 'Draw the plans');
    await j.fill('Требования', 'Read a blueprint');
    await j.tap('Отправить на модерацию');
    await j.accepted('Заявка отправлена');
    final sent = await j.row('Blueprint placement');
    expect(sent['status'], 'submitted');
    expect(sent['description'], contains('Read a blueprint'));
    await client.rpc('fixture_clarify_requirements');
    await j.openDraft('Blueprint placement');
    expect(j.value('Требования'), 'Read a blueprint');
    expect(j.value('Описание'), isEmpty);
  });

  journey(
      'clear obsolete details and preserve an unedited contact on resubmission',
      (j) async {
    await j.openDraft('Clear optional details');
    for (final label in [
      'Местоположение (текст)',
      'Зарплата (необязательно)',
      'Ссылка',
      'Email',
      'Телефон'
    ]) {
      expect(j.value(label), isNotEmpty);
      await j.fill(label, '');
    }
    for (final label in ['Формат занятости', 'Местоположение / удалённо']) {
      final control = find
          .ancestor(of: find.text(label), matching: find.byType(InkWell))
          .first;
      await Scrollable.ensureVisible(j.tester.element(control), alignment: 0.4);
      await j.animate();
      await j.tester.tap(control);
      await j.animate();
      final none = find.widgetWithText(ListTile, '— не указано —');
      await j.until(none);
      await j.tester.tap(none);
      await j.animate();
    }
    await j.tap('Сохранить и отправить снова');
    await j.accepted('Заявка отправлена снова');
    await j.until(find.text('Отправлена'));
    final stored = await j.row('Clear optional details');
    expect(stored['status'], 'submitted');
    expect(stored['rejection_reason'], isNull);
    expect(stored['row_version'], 3);
    expect([stored['employment_type'], stored['work_format']], [null, null]);
    expect([stored['location'], stored['salary_text'], stored['external_url']],
        [null, null, null]);
    expect(stored['contacts'], {'telegram': '@otherdesk'});
  });

  journey(
      'switch accounts and read only the signed-in author’s moderation decisions',
      (j) async {
    await j.tap('Мои заявки');
    await j.until(find.text('Rejected placement'));
    expect(
        find.text('Отклонена\nКомментарий: Programme closed'), findsOneWidget);
    expect(find.text('Peer placement'), findsNothing);
    await j.tester.pumpWidget(const SizedBox.shrink());
    await signIn(1);
    await j.board();
    await j.tap('Мои заявки');
    await j.until(find.text('Peer placement'));
    expect(find.text('Одобрена'), findsOneWidget);
    expect(find.text('Rejected placement'), findsNothing);
    expect((await j.rows()).map((r) => r['title']), ['Peer placement']);
    await j.tester.pumpWidget(const SizedBox.shrink());
    await signIn(0);
    await j.board();
    await j.tap('Мои заявки');
    await j.until(find.text('Rejected placement'));
    expect(find.text('Peer placement'), findsNothing);
  });

  journey('back out of a clarification and reopen the saved draft', (j) async {
    final before = await j.row('Cancel edits');
    await j.openDraft('Cancel edits');
    await j.fill('Краткое описание *', 'Abandoned change');
    final back = find.byType(BackButton);
    await j.tester.tap(back);
    await j.animate();
    await j.tap('Cancel edits');
    expect(j.value('Краткое описание *'), 'Original summary');
    expect(await j.row('Cancel edits'), before);
  });

  journey('correct an invalid vacancy URL and submit exactly once', (j) async {
    await j.tap('Предложить');
    await j.fill('Название *', 'CAD placement');
    await j.fill('Краткое описание *', 'Assist an engineer');
    await j.fill('Ссылка', 'http://example.org/intern');
    await j.tap('Отправить на модерацию');
    await j.until(find.textContaining('https://').hitTestable());
    expect(
        (await j.rows()).where((r) => r['title'] == 'CAD placement'), isEmpty);
    expect(j.value('Название *'), 'CAD placement');
    const prefix = 'https://example.org/';
    final boundary =
        prefix + List.filled(500 - prefix.runes.length, '📐').join();
    expect(boundary.runes.length, 500);
    await j.fill('Ссылка', '${boundary}x');
    await j.tap('Отправить на модерацию');
    await j.until(find.text('Сократите ссылку до 500 символов.').hitTestable());
    expect(
        (await j.rows()).where((r) => r['title'] == 'CAD placement'), isEmpty);
    await j.fill('Ссылка', boundary);
    await j.tap('Отправить на модерацию');
    await j.accepted('Заявка отправлена');
    final sent = await j.row('CAD placement');
    expect(sent['external_url'], boundary);
    expect(sent['status'], 'submitted');
  });
}
