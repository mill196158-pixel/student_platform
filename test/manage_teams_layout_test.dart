import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/manage/manage_teams_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/learning_cubit.dart';
import 'package:student_platform/src/ui/learning/state/learning_state.dart';
import 'package:student_ui/student_ui.dart';

class _Repo implements LearningRepository {
  int joins = 0;
  @override
  Future<String> joinByInviteCode(String code) async {
    joins++;
    return 'id';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cubit extends LearningCubit {
  _Cubit(_Repo repo) : super(repository: repo);
  void show(LearningState value) => emit(value);
}

void main() {
  for (final width in [320.0, 834.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('team search, empty/loading, invite cancel $width dark=$dark',
          (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = _Repo();
        final cubit = _Cubit(repo);
        addTearDown(cubit.close);
        cubit.show(const LearningState(teams: [
          Team(
              id: 'id',
              name: 'Надёжность систем водоснабжения и водоотведения',
              teacher: 'Преподаватель с длинной фамилией',
              icon: 'school',
              groupCode: '')
        ]));
        await tester.pumpWidget(MaterialApp(
            theme: ProductTheme.build(
                brightness: dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!),
            home: BlocProvider<LearningCubit>.value(
                value: cubit, child: const ManageTeamsScreen(groupCode: ''))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), 'НЕСУЩЕСТВУЮЩЕЕ');
        await tester.pumpAndSettle();
        expect(find.text('Ничего не найдено'), findsOneWidget);
        await tester.tap(find.byTooltip('Очистить поиск'));
        await tester.pumpAndSettle();
        expect(find.text('Надёжность систем водоснабжения и водоотведения'),
            findsOneWidget);
        await tester.tap(find.byTooltip('Добавить по коду'));
        await tester.pumpAndSettle();
        final add = find.widgetWithText(FilledButton, 'Добавить');
        expect(tester.widget<FilledButton>(add).onPressed, isNull);
        await tester.enterText(find.byType(TextField).last, '   ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.widget<FilledButton>(add).onPressed, isNull);
        expect(MediaQuery.textScalerOf(tester.element(add)).scale(10), 15);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(repo.joins, 0);
        cubit.show(const LearningState());
        await tester.pumpAndSettle();
        expect(find.text('Команд пока нет'), findsOneWidget);
        cubit.show(const LearningState(loading: true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(ProductLoadingIndicator), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
