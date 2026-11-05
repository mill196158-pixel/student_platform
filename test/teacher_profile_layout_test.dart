import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/teacher_profile_screen.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  var writes = 0;
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
          if (path.endsWith('/get_published_teacher')) {
            body = {
              'full_name': 'Преподаватель с длинным именем и отчеством',
              'about_text':
                  'Научные интересы: системы водоснабжения, очистка стока и эксплуатация сооружений.'
            };
          } else if (path.endsWith('/teacher_difficulty_targets')) {
            body = {
              'id': '00000000-0000-0000-0000-000000000001',
              'about_text': 'Кафедра водоснабжения'
            };
          } else if (path.endsWith('/teacher_difficulty_summaries')) {
            body = {'vote_count': 2, 'score_total': 6};
          } else if (request.method != 'GET' && request.method != 'HEAD') {
            writes++;
            return http.Response('{}', 403, request: request);
          } else {
            body = [];
          }
          return http.Response(jsonEncode(body), 200,
              request: request, headers: {'content-type': 'application/json'});
        }));
  });
  tearDownAll(() => Supabase.instance.dispose());
  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
          'teacher and rating sheet fit $size dark=$dark with large text',
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
            home: const TeacherProfileScreen(
                teacherName: 'Преподаватель',
                teacherId: '00000000-0000-0000-0000-000000000001',
                subjectTitle: 'Надежность систем водоснабжения и водоотведения',
                department: 'Кафедра водоснабжения и природопользования',
                semesterNumber: 12,
                subjectDifficultyAvg: 3.5)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(ListView).first).width,
            lessThanOrEqualTo(760));
        final rate = find.widgetWithText(FilledButton, 'Оценить');
        await tester.ensureVisible(rate);
        await tester.pumpAndSettle();
        await tester.tap(rate);
        await tester.pumpAndSettle();
        expect(find.text('Сложность сдачи преподавателю'), findsOneWidget);
        expect(
            MediaQuery.textScalerOf(
                    tester.element(find.text('Сложность сдачи преподавателю')))
                .scale(10),
            15);
        for (var score = 1; score <= 5; score++) {
          final star = find.byTooltip('$score из 5');
          expect(star, findsOneWidget);
          expect(tester.getSize(star).width, greaterThanOrEqualTo(48));
        }
        expect(tester.takeException(), isNull);
        final close = find.byTooltip('Закрыть без оценки');
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text('Сложность сдачи преподавателю'), findsNothing);
        expect(writes, 0);
      });
    }
  }
}
