import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';

class DelayedDraftStore extends InMemorySharedPreferencesStore {
  DelayedDraftStore() : super.empty();
  final started = Completer<void>();
  final release = Completer<void>();
  bool delay = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (delay && key == 'flutter.global_draft_texts') {
      delay = false;
      started.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}

class FailTextOnceStore extends InMemorySharedPreferencesStore {
  FailTextOnceStore() : super.empty();
  bool fail = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (fail && key == 'flutter.global_draft_texts') {
      fail = false;
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('delayed old write cannot overwrite newer text and files', () async {
    final original = SharedPreferencesStorePlatform.instance;
    final store = DelayedDraftStore();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() async {
      if (!store.release.isCompleted) store.release.complete();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
    final cache = GlobalCache();
    final old = cache.saveDraft('one', 'old', [
      {'name': 'old.pdf'}
    ]);
    await store.started.future;
    final clear = cache.clearDraft('one');
    final fresh = cache.saveDraft('one', 'new', [
      {'name': 'new.pdf'}
    ]);
    final other = cache.saveDraft('two', 'second', [
      {'name': 'second.pdf'}
    ]);
    store.release.complete();
    await Future.wait([old, clear, fresh, other]);
    SharedPreferences.resetStatic();
    final prefs = await SharedPreferences.getInstance();
    final texts = jsonDecode(prefs.getString('global_draft_texts')!) as Map;
    final files = jsonDecode(prefs.getString('global_draft_files')!) as Map;
    expect(texts['one'], 'new');
    expect(texts['two'], 'second');
    expect(files['one'].single['name'], 'new.pdf');
    expect(files['two'].single['name'], 'second.pdf');
  });

  test('failed text save still attempts files and does not stop later saves',
      () async {
    final original = SharedPreferencesStorePlatform.instance;
    final store = FailTextOnceStore();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
    final cache = GlobalCache();
    await cache.saveDraft('failure-case', 'first', [
      {'name': 'keep.pdf'}
    ]);
    var platform = await store.getAll();
    expect(
        (jsonDecode(platform['flutter.global_draft_files'] as String)
                as Map)['failure-case']
            .single['name'],
        'keep.pdf');
    await cache.saveDraft('failure-case', 'next', [
      {'name': 'next.pdf'}
    ]);
    platform = await store.getAll();
    expect(
        (jsonDecode(platform['flutter.global_draft_texts'] as String)
            as Map)['failure-case'],
        'next');
    expect(
        (jsonDecode(platform['flutter.global_draft_files'] as String)
                as Map)['failure-case']
            .single['name'],
        'next.pdf');
    await cache.saveDraft('failure-case', 'bad', [
      {'bad': DateTime.utc(2026)}
    ]);
    platform = await store.getAll();
    expect(
        (jsonDecode(platform['flutter.global_draft_texts'] as String)
            as Map)['failure-case'],
        'bad');
    await cache.saveDraft('failure-case', 'recovered', [
      {'name': 'recovered.pdf'}
    ]);
    platform = await store.getAll();
    expect(
        (jsonDecode(platform['flutter.global_draft_texts'] as String)
            as Map)['failure-case'],
        'recovered');
  });
}
