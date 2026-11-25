import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/notifications/in_app_toast_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

const _owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _peer = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _chat = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _message = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _other = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const _body = 'Новое сообщение';
const _fallback = 'Личное сообщение';
const _name = 'Мария Орлова';

Map<String, dynamic> _data() => {
      'type': 'dm_message',
      'chat_id': _chat,
      'author_id': _peer,
      'peer_id': _peer,
      'message_id': _message,
    };

Map<String, dynamic> _row() => {
      'id': _id,
      'recipient_id': _owner,
      'event_type': 'dm_message',
      'title': 'Пользователь',
      'data': _data(),
      'read_at': null,
      'deleted_at': null,
    };

InAppNotificationEvent _event({Map<String, dynamic> overrides = const {}}) =>
    InAppNotificationEvent(
      type: 'dm_message',
      title: 'Пользователь',
      body: _body,
      payload: PushPayload.tryParse({
        ..._data(),
        'notification_id': _id,
        'peer_name': 'Подставное имя',
        'body': 'Закрытый текст из доставки',
        ...overrides,
      }),
    );

class _Server {
  final rows = <http.Request>[];
  final profiles = <http.Request>[];
  final unexpected = <Uri>[];
  final row = Completer<List<Map<String, dynamic>>>();
  final profile = Completer<List<Map<String, dynamic>>>();

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    Object value;
    if (request.url.host == 'example.invalid' &&
        path == '/rest/v1/app_notifications') {
      rows.add(request);
      value = await row.future;
    } else if (request.url.host == 'example.invalid' &&
        path == '/rest/v1/rpc/get_user_profile') {
      profiles.add(request);
      value = await profile.future;
    } else {
      unexpected.add(request.url);
      return http.Response('[]', 404, request: request);
    }
    return http.Response.bytes(utf8.encode(jsonEncode(value)), 200,
        request: request,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  void returnProfile() => profile.complete([
        {'name': 'Мария', 'surname': 'Орлова'}
      ]);
}

Future<({AuthSessionScope scope, SessionCapabilities caps})> _mount(
    WidgetTester tester, _Server server,
    {OnlineSideEffectBarrier? barrier}) async {
  SharedPreferences.setMockInitialValues({});
  const channel = MethodChannel('com.llfbandit.app_links/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (_) async => null);
  InAppNotificationBus.instance.resetSession();
  await tester.runAsync(() async {
    await Supabase.initialize(
        url: 'https://example.invalid',
        publishableKey: 'test',
        httpClient: MockClient(server.handle),
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false));
    await signInWithFileSession(Supabase.instance.client, _owner, _owner);
  });
  addTearDown(() async {
    InAppNotificationBus.instance.resetSession();
    await Supabase.instance.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    expect(server.unexpected, isEmpty);
  });
  await tester.pumpWidget(AuthSessionScopeHost(
      child: SessionCapabilitiesHost(
    child: MaterialApp(
        builder: (_, child) => InAppToastHost(barrier: barrier, child: child!),
        home: const Scaffold(body: Text('Экран приложения'))),
  )));
  await tester.pump();
  final context = tester.element(find.byType(InAppToastHost));
  final scope = AuthSessionScopeHost.maybeRead(context)!;
  final caps = SessionCapabilitiesHost.maybeRead(context)!;
  final owner = scope.capture()!;
  expect(owner.userId, _owner);
  expect(
      caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(owner)!),
      isTrue);
  await tester.pump();
  return (scope: scope, caps: caps);
}

Future<void> _frame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  final bus = InAppNotificationBus.instance;
  testWidgets(
      'verifies one recipient row and resolves the DM sender in the same banner',
      (tester) async {
    final server = _Server();
    await _mount(tester, server);
    final event = _event();
    bus.emit(event);
    bus.emit(event);
    await _frame(tester);
    expect(find.text(_fallback), findsOneWidget);
    expect(find.text('Пользователь'), findsNothing);
    expect(find.text('Подставное имя'), findsNothing);
    expect(find.text('Закрытый текст из доставки'), findsNothing);
    expect(find.text(_body), findsOneWidget);
    expect(server.rows, hasLength(1));
    final request = server.rows.single;
    expect(request.method, 'GET');
    expect(request.url.queryParameters['id'], 'eq.$_id');
    expect(request.url.queryParameters['recipient_id'], 'eq.$_owner');
    expect(server.profiles, isEmpty);
    final banner = tester.element(find.byType(Dismissible));
    server.row.complete([_row()]);
    await _frame(tester);
    expect(find.text(_fallback), findsOneWidget);
    expect(server.profiles, hasLength(1));
    expect(server.profiles.single.method, 'POST');
    expect(jsonDecode(server.profiles.single.body), {'p_id': _peer});
    bus.emit(event);
    server.returnProfile();
    await _frame(tester);
    expect(find.text(_name), findsOneWidget);
    expect(tester.element(find.byType(Dismissible)), same(banner));
    expect(find.text(_body), findsOneWidget);
    expect(find.text('Закрытый текст из доставки'), findsNothing);
    expect(server.rows, hasLength(1));
    expect(server.profiles, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'verified sender title on the recipient row needs no profile request',
      (tester) async {
    final server = _Server();
    await _mount(tester, server);
    bus.emit(_event());
    server.row.complete([_row()..['title'] = _name]);
    await _frame(tester);
    expect(find.text(_name), findsOneWidget);
    expect(find.text(_body), findsOneWidget);
    expect(server.rows, hasLength(1));
    expect(server.profiles, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('revocation during the row query prevents dispatch to profiles',
      (tester) async {
    final server = _Server();
    final auth = await _mount(tester, server);
    bus.emit(_event());
    await _frame(tester);
    expect(server.rows, hasLength(1));
    auth.caps.block();
    server.row.complete([_row()]);
    await _frame(tester);
    expect(server.profiles, isEmpty);
    expect(find.text(_name), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (description, rowChange, dataChange, eventChange) in [
    ('notification id', {'id': _other}, {}, {}),
    ('recipient', {'recipient_id': _other}, {}, {}),
    ('event type', {'event_type': 'team_message'}, {}, {}),
    ('read row', {'read_at': '2026-01-01'}, {}, {}),
    ('deleted row', {'deleted_at': '2026-01-01'}, {}, {}),
    ('chat', {}, {'chat_id': _other}, {}),
    ('author versus peer', {}, {'author_id': _other}, {}),
    ('recipient as sender', {}, {'author_id': _owner, 'peer_id': _owner}, {}),
    ('self-reported payload type', {}, {'type': 'team_message'}, {}),
    ('self-reported notification id', {}, {'notification_id': _other}, {}),
    ('message id', {}, {'message_id': _other}, {}),
    ('carrier peer', {}, {}, {'peer_id': _other}),
    ('carrier author', {}, {}, {'author_id': _other}),
  ]) {
    testWidgets('rejects mismatched or inactive DM notification: $description',
        (tester) async {
      final server = _Server();
      await _mount(tester, server);
      final row = _row()..addAll(Map<String, dynamic>.from(rowChange));
      row['data'] = {..._data(), ...Map<String, dynamic>.from(dataChange)};
      server.row.complete([row]);
      server.returnProfile();
      bus.emit(_event(overrides: Map<String, dynamic>.from(eventChange)));
      await _frame(tester);
      expect(find.text(_fallback), findsOneWidget);
      expect(find.text(_body), findsOneWidget);
      expect(find.text(_name), findsNothing);
      expect(find.text('Подставное имя'), findsNothing);
      expect(server.rows, hasLength(1));
      expect(server.profiles, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final change in [
    'revoke',
    'new owner',
    'silent replacement then rebuild',
    'barrier'
  ]) {
    testWidgets(
        'removes an already visible sender on $change without a bus reset',
        (tester) async {
      final server = _Server();
      final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
      final auth = await _mount(tester, server, barrier: barrier);
      bus.emit(_event());
      server.row.complete([_row()]);
      server.returnProfile();
      await _frame(tester);
      expect(find.text(_name), findsOneWidget);
      switch (change) {
        case 'revoke':
          auth.caps.block();
          break;
        case 'new owner':
          await tester.runAsync(() =>
              signInWithFileSession(Supabase.instance.client, _other, _other));
          break;
        case 'silent replacement then rebuild':
          final original = auth.scope.capture()!;
          await tester.runAsync(() =>
              signInWithFileSession(Supabase.instance.client, _owner, _other));
          expect(auth.scope.isCurrent(original), isFalse);
          // GoTrue can replace a same-user session without emitting an event.
          tester.element(find.byType(InAppToastHost)).markNeedsBuild();
          break;
        case 'barrier':
          barrier.close();
          break;
      }
      await _frame(tester);
      expect(find.text(_name), findsNothing);
      expect(find.text(_fallback), findsOneWidget);
      expect(server.rows, hasLength(1));
      expect(server.profiles, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final interruption in [
    'owner',
    'revoke',
    'barrier',
    'dismiss',
    'replace'
  ]) {
    testWidgets('discards a late profile after $interruption', (tester) async {
      final server = _Server();
      final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
      final auth = await _mount(tester, server, barrier: barrier);
      bus.emit(_event());
      server.row.complete([_row()]);
      await _frame(tester);
      expect(server.profiles, hasLength(1));
      switch (interruption) {
        case 'owner':
          await tester.runAsync(() =>
              signInWithFileSession(Supabase.instance.client, _other, _other));
          break;
        case 'revoke':
          auth.caps.block();
          break;
        case 'barrier':
          barrier.close();
          break;
        case 'dismiss':
          bus.dismissNotifications({_id});
          break;
        case 'replace':
          bus.emit(const InAppNotificationEvent(
              type: 'schedule_change',
              title: 'Расписание',
              body: '',
              payload: PushPayload(
                  version: 1,
                  type: 'schedule_change',
                  notificationId: _other)));
          break;
      }
      await _frame(tester);
      server.returnProfile();
      await _frame(tester);
      expect(find.text(_name), findsNothing);
      if (interruption == 'replace')
        expect(find.text('Расписание'), findsOneWidget);
      if (interruption == 'dismiss') expect(find.text(_fallback), findsNothing);
      expect(server.profiles, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
