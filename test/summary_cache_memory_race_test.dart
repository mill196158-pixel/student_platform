import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/data/chat_summaries_cache.dart';
import 'package:student_platform/src/ui/friends/data/friends_snapshot_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final chat in [true, false]) {
    final label = chat ? 'chat summaries' : 'friends';
    void reset() => chat
        ? ChatSummariesCache.debugResetForTest()
        : FriendsSnapshotCache.debugResetForTest();
    Future<void> write(String raw) => chat
        ? ChatSummariesCache.write('a', raw)
        : FriendsSnapshotCache.write('a', raw);
    Future<String?> read(Future<SharedPreferences> Function() prefs) => chat
        ? ChatSummariesCache.read('a', preferences: prefs)
        : FriendsSnapshotCache.read('a', preferences: prefs);
    Future<void> initialize(Future<SharedPreferences> Function() prefs) => chat
        ? ChatSummariesCache.initializeCurrentUser(
            preferences: prefs, userIdForTesting: 'a')
        : FriendsSnapshotCache.initializeCurrentUser(
            preferences: prefs, userIdForTesting: 'a');
    String? readSync() => chat
        ? ChatSummariesCache.readSync('a')
        : FriendsSnapshotCache.readSync('a');
    void clear() => chat
        ? ChatSummariesCache.clearMemory()
        : FriendsSnapshotCache.clearMemory();
    final key = chat ? 'my_chats_cache_v2_a' : 'friends_snapshot_cache_v1_a';

    Future<SharedPreferences> oldPrefs() async {
      SharedPreferences.setMockInitialValues({key: 'old'});
      final old = await SharedPreferences.getInstance();
      SharedPreferences.setMockInitialValues({});
      reset();
      return old;
    }

    test('$label delayed read returns newer memory', () async {
      final old = await oldPrefs();
      final pending = Completer<SharedPreferences>();
      final result = read(() => pending.future);
      await write('new');
      pending.complete(old);
      expect(await result, 'new');
      expect(readSync(), 'new');
    });

    test('$label delayed initialization preserves newer memory', () async {
      final old = await oldPrefs();
      final pending = Completer<SharedPreferences>();
      final result = initialize(() => pending.future);
      await write('new');
      pending.complete(old);
      await result;
      expect(readSync(), 'new');
    });

    test('$label clear invalidates delayed read', () async {
      final old = await oldPrefs();
      final pending = Completer<SharedPreferences>();
      final result = read(() => pending.future);
      clear();
      pending.complete(old);
      expect(await result, isNull);
      expect(readSync(), isNull);
    });
  }
}
