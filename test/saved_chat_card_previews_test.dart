import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_action_cards_cache.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/saved_chat_card_previews.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

Session _session(String account, String sid, String project) {
  final start = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final claims = {
    'sub': account,
    'iss': '$project/auth/v1',
    'aud': 'authenticated',
    'role': 'authenticated',
    'iat': start,
    'exp': start + 7200,
    'session_id': sid,
  };
  return fakeSession(account,
      access:
          'header.${base64Url.encode(utf8.encode(jsonEncode(claims)))}.signature');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'exact card preview survives SQLite reopen and observes access revocation',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('student-card-preview-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/chat.db';
    const project = 'https://preview.example';
    const sid = '11111111-1111-4111-8111-111111111111';
    const id = '22222222-2222-4222-8222-222222222222';
    const otherMessage = '33333333-3333-4333-8333-333333333333';
    const entity = '44444444-4444-4444-8444-444444444444';
    const chat = '55555555-5555-4555-8555-555555555555';
    const kind = ChatActionCardKind.topicSelection;
    final message = Message(
        id: id,
        chatId: chat,
        authorId: 'author',
        authorLogin: '',
        authorName: 'Автор',
        text: 'Темы',
        at: DateTime(2026),
        cardKind: kind,
        cardEntityId: entity);
    const entry = ChatActionCardEntry(
        kind: kind,
        entityId: entity,
        cardMessageId: id,
        available: true,
        status: 'open',
        title: 'Проверенный выбор тем',
        canManage: true,
        organizerStats: {'private': 17});
    var session = _session('a', sid, project);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(events.close);
    addTearDown(scope.dispose);
    final caps = SessionCapabilities(scope);
    addTearDown(caps.dispose);
    void allow(SessionCapabilityMode mode) => expect(
        caps.grant(mode, caps.beginAuthorization(scope.capture()!)!), isTrue);
    var db =
        await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    addTearDown(() async {
      if (db.isOpen) await db.close();
    });
    SavedChatCardPreviews openStore() =>
        SavedChatCardPreviews(ProjectChatServerCache(
            db: db,
            scope: scope,
            project: project,
            currentBinding: () => OfflineSessionBinding.fromSession(
                session, '$project/auth/v1')));
    var store = openStore();
    final key = chatActionCardIdentity(message)!;

    allow(SessionCapabilityMode.online);
    await store.record(chat, {key: entry}, isCurrent: () => false);
    allow(SessionCapabilityMode.cacheOnly);
    expect(await store.read(chat, [message], caps), isEmpty);
    allow(SessionCapabilityMode.online);
    await store.record(chat, {key: entry}, isCurrent: () => true);
    expect(await store.read(chat, [message], caps), isEmpty);
    await db.close();
    db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    store = openStore();

    allow(SessionCapabilityMode.cacheOnly);
    final cached = await store.read(
        chat, [message, message.copyWith(id: otherMessage)], caps);
    expect(cached.keys, [key]);
    expect(cached[key]?.title, 'Проверенный выбор тем');
    expect(cached[key]?.canManage, isNull);
    expect(cached[key]?.organizerStats, isNull);
    expect(
        await store.read(
            chat, [message.copyWith(cardEntityId: otherMessage)], caps),
        isEmpty);
    expect(
        await store.read(
            'another-chat', [message.copyWith(chatId: 'another-chat')], caps),
        isEmpty);
    caps.block();
    expect(await store.read(chat, [message], caps), isEmpty);

    session = _session('b', sid, project);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    allow(SessionCapabilityMode.cacheOnly);
    expect(await store.read(chat, [message], caps), isEmpty);
    session = _session('a', otherMessage, project);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    allow(SessionCapabilityMode.cacheOnly);
    expect(await store.read(chat, [message], caps), isEmpty);

    session = _session('a', sid, project);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    allow(SessionCapabilityMode.online);
    await store.record(chat, {key: null}, isCurrent: () => true);
    allow(SessionCapabilityMode.cacheOnly);
    expect(await store.read(chat, [message], caps), isEmpty);
  });
}
