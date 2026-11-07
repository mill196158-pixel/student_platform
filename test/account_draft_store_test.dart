import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:student_platform/src/ui/learning/account_draft_store.dart';

class _DelayedStore extends InMemorySharedPreferencesStore {
  _DelayedStore() : super.empty();
  final started = Completer<void>();
  final release = Completer<void>();
  bool delay = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (delay && key.startsWith('flutter.account_draft_v1_')) {
      delay = false;
      started.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy marker permits only selected conversations and owner', () async {
    SharedPreferences.setMockInitialValues({
      AccountDraftStore.legacyOwnerMarkerKey: jsonEncode({
        'project': 'project', 'owner': 'a', 'conversations': ['selected'],
      }),
    });
    final store = AccountDraftStore();
    expect(await store.mayOfferLegacy('project', 'a', 'selected', () => true), isTrue);
    expect(await store.mayOfferLegacy('project', 'b', 'selected', () => true), isFalse);
    expect(await store.mayOfferLegacy('project', 'a', 'other', () => true), isFalse);
    expect(await store.mayOfferLegacy('project', 'a', 'selected', () => false), isFalse);
  });
  test('corrupt existing snapshot is not mistaken for an empty draft', () async {
    final key = 'account_draft_v1_${base64Url.encode(utf8.encode(jsonEncode(['project', 'a', 'chat'])))}';
    SharedPreferences.setMockInitialValues({key: '{bad'});
    final store = AccountDraftStore();
    await expectLater(store.read('project', 'a', 'chat', () => true), throwsFormatException);
    expect((await SharedPreferences.getInstance()).getString(key), '{bad');
  });
  test('delayed write cannot replace newer text, reply and files', () async {
    final original = SharedPreferencesStorePlatform.instance;
    final storage = _DelayedStore();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = storage;
    addTearDown(() {
      if (!storage.release.isCompleted) storage.release.complete();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = original;
    });
    final store = AccountDraftStore();
    final old = store.write('project', 'a', 'chat', {
      'text': 'old', 'reply': {'id': 'old'}, 'files': [{'name': 'old'}]
    }, () => true);
    await storage.started.future;
    final newer = store.write('project', 'a', 'chat', {
      'text': 'new', 'reply': {'id': 'new'}, 'files': [{'name': 'new'}]
    }, () => true);
    final reading = store.read('project', 'a', 'chat', () => true);
    storage.release.complete();
    await Future.wait([old, newer]);
    final value = await reading;
    expect(value?['text'], 'new');
    expect((value?['reply'] as Map)['id'], 'new');
    expect((value?['files'] as List).single['name'], 'new');
    expect(await store.read('project', 'b', 'chat', () => true), isNull);
  });
}
