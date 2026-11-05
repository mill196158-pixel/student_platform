import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/assignment_details_screen.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Cubit extends TeamCubit {
  _Cubit(Assignment assignment, bool organizer)
      : super(const Team(
            id: 'local',
            name: 'Команда',
            teacher: '',
            groupCode: '',
            icon: 'school')) {
    emit(state.copyWith(assignments: [assignment], isStarosta: organizer));
  }
}

void main() {
  var calls = 0;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://layout.invalid',
        publishableKey: 'local',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async {
          calls++;
          return http.Response('[]', 200, request: request);
        }));
  });
  tearDownAll(() => Supabase.instance.dispose());
  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets('assignment role footer/menu fit $size dark=$dark',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (var mode = 0; mode < 3; mode++) {
          final assignment = Assignment(
              id: 'a',
              title:
                  'Расчётная работа по проектированию систем водоснабжения и водоотведения',
              description: 'Исходные данные и расчётные допущения. ' * 15,
              link: 'https://example.invalid/materials/long-resource-name',
              due: '31.10.2026 18:00',
              attachments: const [
                {
                  'name': 'Пояснительная записка и расчёт оборудования.pdf',
                  'path': 'local-only'
                }
              ],
              published: mode == 0,
              votes: 1,
              completedByMe: false,
              createdBy: 'student',
              createdAt: DateTime(2026));
          final cubit = _Cubit(assignment, mode == 2);
          await tester.pumpWidget(MaterialApp(
              theme: ProductTheme.build(
                  brightness: dark ? Brightness.dark : Brightness.light),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(1.5)),
                  child: child!),
              home: BlocProvider<TeamCubit>.value(
                  value: cubit,
                  child: const AssignmentDetailsScreen(assignmentId: 'a'))));
          await tester.pumpAndSettle();
          expect(
              find.text(mode == 0
                  ? 'Отметить как выполнено'
                  : mode == 1
                      ? 'Голосовать «за»'
                      : 'Опубликовать'),
              findsOneWidget);
          expect(tester.getSize(find.byType(FilledButton)).width,
              lessThanOrEqualTo(680));
          expect(
              tester.getSize(find.byType(FilledButton)).height, lessThan(170));
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Ещё'));
          await tester.pumpAndSettle();
          expect(find.text('Поделиться'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tapAt(const Offset(20, 150));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          await cubit.close();
        }
        expect(calls, 0);
      });
    }
  }
}
