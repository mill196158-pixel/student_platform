import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _origin = 'http://127.0.0.1:55321';

class _LocalSockets extends HttpOverrides {}

/// Holds one successful, real server response until the tester releases it.
class _Delay {
  final ready = Completer<int>();
  final release = Completer<void>();
  final sent = Completer<void>();
}

class _LocalHttp extends http.BaseClient {
  final inner = IOClient(
      _LocalSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final delays = <String, _Delay>{};
  int incomingReads = 0;
  int classmatesReads = 0;
  _Delay hold(String rpc) => delays[rpc] = _Delay();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _origin) throw StateError('Loopback only');
    final path = request.url.pathSegments.last;
    if (path == 'get_my_incoming_friend_requests') incomingReads++;
    if (path == 'get_my_classmates') classmatesReads++;
    final delay = delays.remove(path);
    final response = await inner.send(request);
    if (delay == null) return response;
    final bytes = await response.stream.toBytes();
    delay.ready.complete(response.statusCode);
    await delay.release.future;
    delay.sent.complete();
    return http.StreamedResponse(Stream.value(bytes), response.statusCode,
        headers: response.headers, request: request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final raw = Platform.environment['STUDENT_FRIEND_SCENARIOS'];
  if (raw != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets('six friend journeys against two real local student sessions',
      (tester) async {
    final config = jsonDecode(raw!) as Map;
    final students = (config['students'] as List).cast<Map>();
    if (config['api'] != _origin ||
        students.length != 2 ||
        students[0]['id'] == students[1]['id'] ||
        students.any((s) =>
            !RegExp(r'^e2e_social_[0-9a-f]{12}_(first|peer)@student\.local$')
                .hasMatch(s['email'] as String))) {
      throw StateError('Two disposable local social students required');
    }
    await HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('com.llfbandit.app_links/events'),
              (_) async => null);
      final http = _LocalHttp();
      await Supabase.initialize(
          url: _origin,
          publishableKey: config['key'],
          httpClient: http,
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false, detectSessionInUri: false));
      final me = Supabase.instance.client,
          peer = SupabaseClient(_origin, config['key']);
      final releases = <_Delay>[];

      Future<void> until(
          FutureOr<bool> Function() predicate, String description) async {
        final end = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(end)) {
          if (await predicate()) return;
          await tester.pump(const Duration(milliseconds: 45));
        }
        fail(description);
      }

      Future<void> visible(Finder target) =>
          until(() => target.evaluate().isNotEmpty, 'Missing $target');
      Future<void> tap(Finder target) async {
        await visible(target);
        await tester.ensureVisible(target.first);
        await until(() => target.first.hitTestable().evaluate().isNotEmpty,
            'Cannot tap $target');
        await tester.tap(target.first);
        await tester.pump(const Duration(milliseconds: 300));
      }

      final field = find.byKey(const ValueKey('friends_search_field'));
      final peerName = find.text('Student ${students.last['surname']}');
      Future<void> closeProfile() async {
        await tester.binding.handlePopRoute();
        await until(
            () => find
                .byType(FriendProfileScreen, skipOffstage: false)
                .evaluate()
                .isEmpty,
            'Profile route stayed mounted');
        await visible(field);
      }

      Future<void> refresh() async {
        await until(
            () => find.byType(RefreshProgressIndicator).evaluate().isEmpty,
            'The previous pull-to-refresh did not finish');
        final previousIncoming = http.incomingReads;
        final previousClassmates = http.classmatesReads;
        await tester.drag(find.byType(ListView).first, const Offset(0, 550));
        await until(
            () =>
                http.incomingReads > previousIncoming &&
                http.classmatesReads > previousClassmates,
            'The pull gesture did not start a fresh list and inbox request');
      }

      Future<List<String>> ids(SupabaseClient client, String function) async =>
          (await client.rpc(function) as List)
              .map((r) => r['id'] as String)
              .toList();

      try {
        for (final (client, student) in [
          (me, students.first),
          (peer, students.last)
        ]) {
          final session = await client.auth.signInWithPassword(
              email: student['email'], password: student['password']);
          expect(session.user?.id, student['id']);
        }
        final myId = me.auth.currentUser!.id,
            peerId = peer.auth.currentUser!.id;
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.light().data,
            home: Scaffold(body: Builder(builder: (context) {
              return TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const MyFriendsScreen())),
                  child: const Text('Открыть друзей'));
            }))));
        final openFriends = find.text('Открыть друзей');
        final initialLoad = http.hold('get_my_friends_bulk');
        releases.add(initialLoad);
        final originalChannels = me.getChannels().toSet();
        await tap(openFriends);
        await until(() => initialLoad.ready.isCompleted,
            'Opening did not load friends');
        expect(await initialLoad.ready.future, 200);
        await tester.binding.handlePopRoute();
        await until(
            () => find
                .byType(MyFriendsScreen, skipOffstage: false)
                .evaluate()
                .isEmpty,
            'Closed friends list stayed mounted');
        initialLoad.release.complete();
        await initialLoad.sent.future;
        await tester.pump(const Duration(milliseconds: 450));
        expect(me.getChannels().toSet(), originalChannels,
            reason:
                'Leaving during loading created stale friends subscriptions');
        await tap(openFriends);
        await visible(field);
        final surname = students.last['surname'] as String;
        final held = http.hold('search_users_global');
        releases.add(held);
        await tester.enterText(field, surname);
        await until(
            () => held.ready.isCompleted, 'First real search never arrived');
        expect(await held.ready.future, 200);
        await tester.enterText(field, 'unmatched$surname');
        await visible(find.text('Ничего не найдено'));
        held.release.complete();
        await held.sent.future;
        await tester.pump(const Duration(milliseconds: 200));
        expect(peerName, findsNothing,
            reason: 'Old search overwrote newer query');
        expect(find.text('Ничего не найдено'), findsOneWidget);
        // Leaving a slow-opening profile must return to the same search results.
        final profile = http.hold('get_user_profile');
        releases.add(profile);
        await tester.enterText(field, surname);
        await tap(peerName);
        await visible(find.byType(FriendProfileScreen));
        expect(
            tester
                .widget<FriendProfileScreen>(find.byType(FriendProfileScreen))
                .userId,
            peerId);
        await until(() => profile.ready.isCompleted,
            'Real profile lookup did not start');
        expect(await profile.ready.future, 200);
        await closeProfile();
        profile.release.complete();
        await profile.sent.future;
        await tester.pump(const Duration(milliseconds: 450));
        expect(tester.takeException(), isNull);
        expect(peerName, findsOneWidget);
        debugPrint(
            'PASS FRIEND-1 latest student search, open profile, back during slow lookup');

        await tap(peerName);
        await tap(find.text('Добавить'));
        await visible(find.text('Отменить'));
        expect(await ids(peer, 'get_my_incoming_friend_requests'), [myId]);
        debugPrint(
            'PASS FRIEND-2 send a request from profile and verify recipient inbox');

        await tap(find.text('Отменить'));
        await visible(find.text('Добавить'));
        expect(await ids(peer, 'get_my_incoming_friend_requests'), isEmpty);
        debugPrint(
            'PASS FRIEND-3 retract request and verify it disappears for recipient');

        await closeProfile();
        await tester.enterText(field, '');
        await visible(find.text('Мои друзья'));
        await peer.rpc('send_friend_request', params: {'p_user_id': myId});
        final classmates = http.hold('get_my_classmates');
        releases.add(classmates);
        await refresh();
        await until(() => classmates.ready.isCompleted,
            'The first refresh never reached the classmates endpoint');
        expect(await classmates.ready.future, 200);
        await tap(find.byTooltip('Отклонить'));
        await until(() => find.byTooltip('Отклонить').evaluate().isEmpty,
            'Declined request stayed visible');
        expect(await ids(me, 'get_my_incoming_friend_requests'), isEmpty);
        expect(await ids(peer, 'get_my_friends_bulk'), isEmpty);
        debugPrint(
            'PASS FRIEND-4 decline a received request without creating a friendship');

        await peer.rpc('send_friend_request', params: {'p_user_id': myId});
        expect(await ids(me, 'get_my_incoming_friend_requests'), [peerId]);
        expect(find.byType(RefreshProgressIndicator), findsOneWidget);
        classmates.release.complete();
        await refresh();
        final peerRequests =
            find.widgetWithText(InkWell, 'Student ${students.last['surname']}');
        await tap(find.descendant(
            of: peerRequests, matching: find.byTooltip('Принять')));
        await until(() => find.byTooltip('Принять').evaluate().isEmpty,
            'Accepted request stayed visible');
        expect(await ids(me, 'get_my_friends_bulk'), [peerId]);
        expect(await ids(peer, 'get_my_friends_bulk'), [myId]);
        final friendsTab = find.descendant(
            of: find.byType(ListView), matching: find.text('Друзья'));
        await tap(friendsTab);
        await tap(peerName);
        await visible(find.text('В друзьях'));
        debugPrint(
            'PASS FRIEND-5 accept a new request and see the friendship from both accounts');

        await tap(find.text('Удалить'));
        await visible(find.text('Добавить'));
        await closeProfile();
        await tap(friendsTab);
        await visible(find.text('Друзей пока нет'));
        expect(await ids(me, 'get_my_friends_bulk'), isEmpty);
        expect(await ids(peer, 'get_my_friends_bulk'), isEmpty);
        debugPrint(
            'PASS FRIEND-6 remove a friend and verify removal for both accounts');
        expect(tester.takeException(), isNull);
      } finally {
        for (final delay in releases) {
          if (!delay.release.isCompleted) delay.release.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await peer.dispose();
        await Supabase.instance.dispose();
        http.close();
      }
    }, _LocalSockets());
  }, skip: raw == null);
}
