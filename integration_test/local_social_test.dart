import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:student_platform/src/ui/profile/edit_profile_screen.dart';
import 'package:student_platform/src/themes/themes.dart';

// Real screens + real local HTTP. This intentionally excludes production main,
// Firebase bootstrap and missing historical backend contracts.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  const password = String.fromEnvironment('E2E_PASSWORD');
  if (url != 'http://10.0.2.2:55321' || key.isEmpty || password.isEmpty) {
    throw StateError(
        'Local E2E defines required; production fallback forbidden');
  }

  testWidgets('local friend UI and persisted profile status', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: url, anonKey: key);
    final me = Supabase.instance.client;
    final peer = SupabaseClient(url, key);
    addTearDown(() async {
      await peer.dispose();
      await Supabase.instance.dispose();
    });
    await me.auth.signInWithPassword(
        email: '99000001@student.local', password: password);
    await peer.auth.signInWithPassword(
        email: '99000002@student.local', password: password);
    final myId = me.auth.currentUser!.id;
    final peerId = peer.auth.currentUser!.id;
    await me.rpc('remove_friend', params: {'p_user_id': peerId});
    await me.rpc('cancel_friend_request', params: {'p_user_id': peerId});
    await peer.rpc('cancel_friend_request', params: {'p_user_id': myId});

    Future<void> waitFor(Finder target) async {
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (target.evaluate().isNotEmpty) return;
      }
      fail('Expected UI did not appear: $target');
    }

    Future<void> screen(Widget child) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester
          .pumpWidget(MaterialApp(theme: AppTheme.light().data, home: child));
    }

    await screen(FriendProfileScreen(userId: peerId));
    await waitFor(find.text('Добавить'));
    await tester.ensureVisible(find.text('Добавить'));
    await tester.tap(find.text('Добавить'));
    await waitFor(find.text('Заявка отправлена'));
    final incoming = await peer.rpc('get_my_incoming_friend_requests') as List;
    expect(incoming.length, 1);
    await peer.rpc('accept_friend_request', params: {'p_user_id': myId});
    await screen(FriendProfileScreen(userId: peerId));
    await waitFor(find.text('В друзьях'));
    await screen(const MyFriendsScreen());
    await waitFor(find.textContaining('Synthetic'));
    expect((await me.rpc('get_my_friends_bulk') as List).length, 1);

    await me.from('users').update({'status': 'Онлайн'}).eq('id', myId);
    final profile = await me.from('users').select().eq('id', myId).single();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user', jsonEncode(profile));
    await screen(const EditProfileScreen());
    await waitFor(find.text('Онлайн'));
    await tester.ensureVisible(find.text('Онлайн'));
    await tester.tap(find.text('Онлайн'));
    await waitFor(find.text('В библиотеке'));
    await tester.tap(find.text('В библиотеке'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
        (await me
            .from('users')
            .select('status')
            .eq('id', myId)
            .single())['status'],
        'В библиотеке');
    await screen(const EditProfileScreen());
    await waitFor(find.text('В библиотеке'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
