import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/exams/exams_screen.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'cold_start_session_test.dart' show sessionFixture;

void main() {
  var writes = 0;
  const subject =
      'Подготовка к процедуре защиты и защита выпускной квалификационной работы';
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://layout.invalid',
        publishableKey: 'layout-only',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async {
          dynamic body;
          final path = request.url.path;
          if (path.endsWith('/student_enrollments')) {
            body = {'group_id': 'group-1'};
          } else if (path.endsWith('/group_term_semesters')) {
            body = [
              {'semester_number': 4}
            ];
          } else if (path.endsWith('/group_academic_profiles')) {
            body = {'nominal_semesters': 4};
          } else if (path.endsWith('/rpc_get_my_subjects_v2')) {
            body = [
              {
                'subject_offering_id': '00000000-0000-0000-0000-000000000001',
                'subject_title': subject,
                'semester_number': 4,
                'control_form': 'экзамен',
                'department': 'Кафедра водоснабжения и водоотведения',
                'can_vote': true,
                'can_open_chat': false,
                'avg_difficulty_global': 3.5,
                'short_description':
                    'Расчётные основы и применение инженерных решений.',
                'how_to_pass':
                    'Подготовить пояснительную записку и защитить решения.',
                'credits': 6,
                'hours_total': 216
              },
              {
                'subject_offering_id': '00000000-0000-0000-0000-000000000003',
                'subject_title': 'Инженерные сооружения',
                'semester_number': 4,
                'control_form': 'зачет',
                'department': 'Кафедра гидравлики',
                'can_vote': true,
                'can_open_chat': false,
                'user_vote': {'difficulty_rating': 4},
              },
              {
                'subject_offering_id': '00000000-0000-0000-0000-000000000002',
                'subject_title': 'Гидравлика и основы гидрологии',
                'semester_number': 3,
                'control_form': 'зачет',
                'department': 'Кафедра гидравлики',
                'can_vote': false,
                'can_open_chat': false,
                'credits': 4,
                'hours_total': 144
              },
            ];
          } else {
            if (request.method != 'GET' && request.method != 'HEAD') writes++;
            body = [];
          }
          return http.Response(jsonEncode(body), 200,
              request: request, headers: {'content-type': 'application/json'});
        }));
    await Supabase.instance.client.auth.setInitialSession(jsonEncode(
        sessionFixture(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600)));
  });
  tearDownAll(() => Supabase.instance.dispose());

  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
          'legacy exams content, details, vote and export fit $size dark=$dark',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
            theme: ProductTheme.build(
                brightness: dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!),
            home: const ExamsScreen()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Пример'), findsNothing);
        final status = find.byKey(const ValueKey('exam-voted-status'));
        final statusBox =
            tester.widget<Container>(status).decoration! as BoxDecoration;
        final statusText =
            tester.widget<Text>(find.text('Оценено')).style!.color!;
        final surface = Theme.of(tester.element(status)).colorScheme.surface;
        final background = Color.alphaBlend(statusBox.color!, surface);
        final first = statusText.computeLuminance();
        final second = background.computeLuminance();
        final contrast = first > second
            ? (first + .05) / (second + .05)
            : (second + .05) / (first + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        expect(tester.getSize(find.byTooltip('Ещё')).height,
            greaterThanOrEqualTo(48));
        expect(tester.getSize(find.byType(ListView).first).width,
            lessThanOrEqualTo(900));
        await tester.ensureVisible(find.text(subject).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(subject).first);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Закрыть'), findsOneWidget);
        expect(
            MediaQuery.textScalerOf(tester.element(find.byTooltip('Закрыть')))
                .scale(10),
            15);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Закрыть'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('Оценить').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Оценить').first);
        await tester.pumpAndSettle();
        expect(find.text('Оценить сложность'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Ещё'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Скачать PDF'));
        await tester.pumpAndSettle();
        expect(find.text('Экспортировать информацию'), findsOneWidget);
        expect(
            MediaQuery.textScalerOf(
                    tester.element(find.text('Экспортировать информацию')))
                .scale(10),
            15);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Закрыть'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Весь учебный план'), 200,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(find.text('Весь учебный план'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Весь учебный план'));
        await tester.pumpAndSettle();
        final semester = find.widgetWithText(OutlinedButton, 'Семестр 3');
        await tester.scrollUntilVisible(semester, 160,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(semester);
        await tester.pumpAndSettle();
        await tester.tap(semester);
        await tester.pumpAndSettle();
        expect(find.text('Гидравлика и основы гидрологии'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(writes, 0);
      });
    }
  }
}
