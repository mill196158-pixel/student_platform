import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';

class FaultTransport extends http.BaseClient {
  final inner = http.Client();
  String mode = '';
  int sendCalls = 0;
  bool failSettings = false;
  int settingsCalls = 0;
  Completer<void>? committed;
  Completer<void>? release;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/chat_user_settings')) {
      settingsCalls++;
      if (failSettings) throw const SocketException('settings offline');
    }
    if (request.url.path.endsWith('/rpc/send_dm_message_once')) {
      sendCalls++;
      if (mode == 'offline') throw const SocketException('test offline');
      final response = await inner.send(request);
      final bytes = await response.stream.toBytes();
      if (mode == 'lost-response')
        throw const SocketException('test response lost after commit');
      if (mode == 'switch') {
        committed!.complete();
        await release!.future;
      }
      return http.StreamedResponse(Stream.value(bytes), response.statusCode,
          headers: response.headers, request: request);
    }
    return inner.send(request);
  }

  @override
  void close() {
    inner.close();
    super.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  const login = String.fromEnvironment('E2E_LOGIN');
  const peerLogin = String.fromEnvironment('E2E_PEER_LOGIN');
  const password = String.fromEnvironment('E2E_PASSWORD');
  if (!const bool.fromEnvironment('E2E_LIVE_APPROVED') ||
      url != 'https://gwdanmwluhrcfxbnplwd.supabase.co' ||
      !login.startsWith('e2e_')) {
    throw StateError('Approved synthetic fixture required');
  }
  testWidgets(
      'real RPC commit loss, offline retry, hydration failure and account isolation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final transport = FaultTransport();
    await Supabase.initialize(url: url, anonKey: key, httpClient: transport);
    final me = Supabase.instance.client;
    final peer = SupabaseClient(url, key);
    addTearDown(() async {
      await DmApi.clearSessionState();
      await peer.dispose();
      await Supabase.instance.dispose();
      transport.close();
    });
    await me.auth
        .signInWithPassword(email: '$login@student.local', password: password);
    await peer.auth.signInWithPassword(
        email: '$peerLogin@student.local', password: password);
    await ChatMessageCacheStore.initializeCurrentUser();
    final uid = me.auth.currentUser!.id;
    final peerId = peer.auth.currentUser!.id;
    final chat =
        await me.rpc('ensure_dm_chat', params: {'p_partner': peerId}) as String;
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('Проверка повторной отправки'))));
    final prefix = 'transport-${DateTime.now().microsecondsSinceEpoch}';
    final floor = DateTime.utc(2020);
    await ChatMessageCacheStore.replace(
        chatId: chat, userId: uid, messages: [], clearedAt: floor);
    DmApi.invalidateClearedAt(chat);
    transport.failSettings = true;
    final settingsBefore = transport.settingsCalls;
    expect(await DmApi.loadClearedAt(chat), floor);
    final afterFirst = transport.settingsCalls;
    expect(afterFirst, greaterThan(settingsBefore));
    expect(await DmApi.loadClearedAt(chat), floor);
    expect(transport.settingsCalls, greaterThan(afterFirst));
    transport.failSettings = false;
    DmApi.invalidateClearedAt(chat);
    Future<int> count(String text) async {
      final rows = await peer
          .rpc('get_chat_messages_page', params: {'p_chat_id': chat}) as List;
      return rows.where((r) => r['text'] == text).length;
    }

    for (final mode in ['offline', 'lost-response']) {
      transport.mode = mode;
      final text = '$prefix $mode';
      await expectLater(DmApi.sendText(chatId: chat, text: text),
          throwsA(isA<SocketException>()));
      expect(await count(text), mode == 'offline' ? 0 : 1);
      final failed = ChatMessageCacheStore.messagesSync(chat)
          .singleWhere((m) => m.text == text);
      expect(failed.isFailed, isTrue);
      transport.mode = '';
      final id = await DmApi.retryFailedText(chatId: chat, message: failed);
      expect(id, isNotEmpty);
      expect(await count(text), 1);
    }
    final before = transport.sendCalls;
    DmApi.debugLoadMessageById = (
            {required chatId, required messageId}) async =>
        throw StateError('hydration failure');
    final hydratedId =
        await DmApi.sendText(chatId: chat, text: '$prefix hydration');
    expect(hydratedId, isNotEmpty);
    expect(transport.sendCalls, before + 1);
    expect(await count('$prefix hydration'), 1);
    expect(
        ChatMessageCacheStore.messagesSync(chat)
            .singleWhere((m) => m.id == hydratedId)
            .isSending,
        isFalse);
    DmApi.debugLoadMessageById = null;
    transport.mode = 'switch';
    transport.committed = Completer();
    transport.release = Completer();
    final inFlight = DmApi.sendText(chatId: chat, text: '$prefix account');
    await transport.committed!.future;
    await DmApi.clearSessionState();
    await ChatMessageCacheStore.clearOnLogout();
    await me.auth.signInWithPassword(
        email: '$peerLogin@student.local', password: password);
    await ChatMessageCacheStore.initializeCurrentUser();
    transport.release!.complete();
    expect(await inFlight, isNotEmpty);
    expect(ChatMessageCacheStore.messagesSync(chat, userId: peerId), isEmpty);
    expect(ChatMessageCacheStore.messagesSync(chat, userId: uid), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
