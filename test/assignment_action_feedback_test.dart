import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/assignment_details_screen.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';

class ControlledAssignments extends TeamCubit {
  ControlledAssignments()
      : super(Team(
            id: 'fixture',
            name: 'Fixture',
            teacher: '',
            groupCode: '',
            icon: 'T')) {
    emit(state.copyWith(isStarosta: true, assignments: [
      Assignment(
          id: 'task',
          title: 'Fixture task',
          description: '',
          published: false,
          votes: 0,
          completedByMe: false,
          createdBy: 'student',
          createdAt: DateTime(2026))
    ]));
  }
  final completion = Completer<void>();
  int writes = 0;
  @override
  Future<void> publishAssignment(String assignmentId) {
    writes++;
    return completion.future;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://localhost:54321',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
  });
  tearDownAll(() => Supabase.instance.dispose());
  testWidgets(
      'publish waits, blocks double click and preserves screen on failure',
      (t) async {
    final cubit = ControlledAssignments();
    addTearDown(cubit.close);
    await t.pumpWidget(MaterialApp(
        home: BlocProvider<TeamCubit>.value(
            value: cubit,
            child: const AssignmentDetailsScreen(assignmentId: 'task'))));
    await t.tap(find.text('Опубликовать'));
    await t.pump();
    await t.tap(find.text('Опубликовать'));
    await t.pump();
    expect(cubit.writes, 1);
    expect(find.text('Задание опубликовано'), findsNothing);
    cubit.completion.completeError(StateError('offline'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Не удалось сохранить. Повторите.'), findsOneWidget);
    expect(find.text('Fixture task'), findsOneWidget);
    expect(find.text('Задание опубликовано'), findsNothing);
  });
  testWidgets('missing assignment never falls back to another assignment',
      (t) async {
    final cubit = ControlledAssignments();
    addTearDown(cubit.close);
    await t.pumpWidget(MaterialApp(
        home: BlocProvider<TeamCubit>.value(
            value: cubit,
            child: const AssignmentDetailsScreen(assignmentId: 'missing'))));
    expect(find.text('Задание недоступно'), findsOneWidget);
    expect(find.text('Опубликовать'), findsNothing);
    expect(find.text('Fixture task'), findsNothing);
  });
}
