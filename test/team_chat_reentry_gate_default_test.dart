import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat_tab.dart';
import 'package:student_platform/src/ui/learning/widgets/reentry_image_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

class _Repo implements LearningRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ordinary team gate only covers an initially cached image list',
      (tester) async {
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('team-gate-default-')))!;
    const links = MethodChannel('com.llfbandit.app_links/events');
    const keyboard = MethodChannel('keyboard_image_channel');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    messenger.setMockMethodCallHandler(keyboard, (_) async => null);
    final pathRelease = Completer<String>();
    final pathEntered = Completer<void>();
    messenger.setMockMethodCallHandler(paths, (_) async {
      if (!pathEntered.isCompleted) pathEntered.complete();
      return pathRelease.future;
    });
    await tester.runAsync(() => Supabase.initialize(
      url: 'https://example.test', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async => http.Response('[]', 200,
        request: request, headers: {'content-type': 'application/json'})),
    ));
    await tester.runAsync(() => signInWithFileSession(Supabase.instance.client,
      'gate-owner', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
    addTearDown(() async {
      if (!pathRelease.isCompleted) pathRelease.complete(root.path);
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(links, null);
      messenger.setMockMethodCallHandler(keyboard, null);
      messenger.setMockMethodCallHandler(paths, null);
      if (await root.exists()) {
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await root.resolveSymbolicLinks();
        if (!p.isWithin(temp, target) ||
            !p.basename(target).startsWith('team-gate-default-')) {
          throw StateError('Unsafe test directory');
        }
        await root.delete(recursive: true);
      }
    });
    const team = Team(id: 'team', name: 'Team', teacher: '', groupCode: '', icon: 'T');
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/qr.png';
    final attachment = ChatFile(id: 'f', chatId: 'chat', messageId: 'm',
      fileName: 'qr.png', fileKey: 'chats/test/qr.png', fileUrl: url,
      fileType: 'image/png', fileSize: 1, uploadedBy: 'owner', uploadedAt: DateTime.utc(2026));
    final message = Message(id: 'm', chatId: 'chat', authorId: 'owner',
      authorLogin: '', authorName: 'Owner', text: 'photo', at: DateTime.utc(2026),
      attachments: [attachment]);
    Widget app(TeamCubit cubit) => MaterialApp(home: BlocProvider.value(
      value: cubit, child: const Scaffold(body: ChatTab())));
    Finder listOpacity() => find.descendant(of: find.byType(ReentryImageGate),
      matching: find.byType(Opacity)).first;

    final lateCubit = TeamCubit(team, repository: _Repo());
    lateCubit.emit(TeamState(team: team, chatHasSnapshot: false));
    await tester.pumpWidget(app(lateCubit));
    expect(tester.widget<Opacity>(listOpacity()).opacity, 1);
    lateCubit.emit(TeamState(team: team, chatHasSnapshot: true, chat: [message]));
    await tester.pump();
    expect(tester.widget<Opacity>(listOpacity()).opacity, 1,
      reason: 'a previously visible list must not be hidden on a late snapshot');
    await tester.pumpWidget(const SizedBox.shrink());
    await lateCubit.close();

    final readyCubit = TeamCubit(team, repository: _Repo());
    readyCubit.emit(TeamState(team: team, chatHasSnapshot: true, chat: [message]));
    await tester.pumpWidget(app(readyCubit));
    expect(tester.widget<Opacity>(listOpacity()).opacity, 0);
    expect(find.byType(TextField), findsWidgets,
      reason: 'the composer is outside the covered list');
    await tester.enterText(find.byType(TextField).last, 'черновик');
    expect(find.text('черновик'), findsOneWidget,
      reason: 'the composer remains usable while the cached list is covered');
    await tester.runAsync(() => pathEntered.future);
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is StateError &&
          details.exception.toString().contains('Выход из аккаунта не завершён')) {
        // The pending image stream may finish after logout removed its listener.
      } else {
        previousOnError?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = previousOnError);
    ChatFileAccess.fenceForLogout();
    pathRelease.complete(root.path);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(find.byType(RawImage), findsNothing,
      reason: 'logout/denial must not expose an image while the gate waits');
    expect(tester.widget<Opacity>(listOpacity()).opacity, 1,
      reason: 'a denied image must release the covered list');
    await tester.pumpWidget(const SizedBox.shrink());
    await readyCubit.close();
  });
}
