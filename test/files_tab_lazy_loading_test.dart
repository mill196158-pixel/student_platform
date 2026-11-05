import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/files_tab.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  var requests = 0;
  Completer<http.Response>? pending;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://files-test.invalid',
      publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
      httpClient: MockClient((request) async {
        requests++;
        if (pending != null) return pending!.future;
        return http.Response('[]', 200, request: request);
      }),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets('loads files only on first activation', (tester) async {
    requests = 0;
    final cubit = TeamCubit(const Team(
      id: 'team', name: 'Team', teacher: '', groupCode: '', icon: '',
    ));
    addTearDown(cubit.close);
    Widget app(bool active) => MaterialApp(
      home: BlocProvider.value(
        value: cubit,
        child: Scaffold(body: FilesTab(isActive: active)),
      ),
    );

    await tester.pumpWidget(app(false));
    await tester.pump();
    expect(requests, 0);
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(requests, 1);
    await tester.pumpWidget(app(false));
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(requests, 1);
  });

  testWidgets('closing while the request fails does not access disposed context',
      (tester) async {
    requests = 0;
    pending = Completer<http.Response>();
    final cubit = TeamCubit(const Team(
      id: 'team', name: 'Team', teacher: '', groupCode: '', icon: '',
    ));
    addTearDown(cubit.close);
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider.value(
        value: cubit,
        child: const Scaffold(body: FilesTab()),
      ),
    ));
    await tester.pump();
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
    pending!.completeError(StateError('offline'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    pending = null;
  });
}
