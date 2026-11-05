import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/serial_auth_local_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Storage extends LocalStorage {
  final calls = <String>[];
  String? value;
  Completer<void>? gate;
  bool failNext = false;
  @override
  Future<void> initialize() async {
    calls.add('init');
  }

  @override
  Future<bool> hasAccessToken() async {
    calls.add('has');
    return value != null;
  }

  @override
  Future<String?> accessToken() async {
    calls.add('read');
    return value;
  }

  @override
  Future<void> persistSession(String data) async {
    calls.add('write');
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('storage');
    }
    value = data;
  }

  @override
  Future<void> removePersistedSession() async {
    calls.add('remove');
    value = null;
  }
}

class _SyncThrowStorage extends _Storage {
  @override
  Future<void> persistSession(String data) => throw StateError('sync');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('writes, removal, reads and drain follow invocation order', () async {
    final delegate = _Storage()..gate = Completer<void>();
    final storage = SerialAuthLocalStorage(delegate);
    await storage.initialize();
    final write = storage.persistSession('first');
    final remove = storage.removePersistedSession();
    final write2 = storage.persistSession('second');
    final read = storage.accessToken();
    final drain = storage.drain();
    await Future<void>.delayed(Duration.zero);
    expect(delegate.calls, ['init', 'write']);
    delegate.gate!.complete();
    await write;
    await remove;
    await write2;
    expect(await read, 'second');
    await drain;
    expect(delegate.calls, ['init', 'write', 'remove', 'write', 'read']);
  });
  test('failed call does not poison later calls', () async {
    final delegate = _Storage()..failNext = true;
    final storage = SerialAuthLocalStorage(delegate);
    await expectLater(storage.persistSession('first'), throwsStateError);
    await storage.persistSession('second');
    expect(await storage.accessToken(), 'second');
  });
  test('synchronous delegate errors preserve queue progress', () async {
    final storage = SerialAuthLocalStorage(_SyncThrowStorage());
    await expectLater(storage.persistSession('x'), throwsStateError);
    expect(await storage.hasAccessToken(), isFalse);
    await storage.drain();
  });
  test('drain waits only for operations queued before it', () async {
    final delegate = _Storage();
    final storage = SerialAuthLocalStorage(delegate);
    await storage.persistSession('first');
    final boundary = storage.drain();
    delegate.gate = Completer<void>();
    final later = storage.persistSession('second');
    await boundary;
    expect(delegate.value, 'first');
    delegate.gate!.complete();
    await later;
    expect(delegate.value, 'second');
  });
  test('timing out drain does not allow later operations to overtake',
      () async {
    final delegate = _Storage()..gate = Completer<void>();
    final storage = SerialAuthLocalStorage(delegate);
    final write = storage.persistSession('first');
    await expectLater(storage.drain().timeout(const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()));
    final remove = storage.removePersistedSession();
    await Future<void>.delayed(Duration.zero);
    expect(delegate.calls, ['write']);
    delegate.gate!.complete();
    await write;
    await remove;
    expect(delegate.calls, ['write', 'remove']);
  });
  test('SDK SharedPreferences delegate keeps existing key and format',
      () async {
    SharedPreferences.setMockInitialValues(
        {'sdk-test-key': 'existing', 'other': 'safe'});
    final storage = SerialAuthLocalStorage(
        SharedPreferencesLocalStorage(persistSessionKey: 'sdk-test-key'));
    await storage.initialize();
    expect(await storage.hasAccessToken(), isTrue);
    expect(await storage.accessToken(), 'existing');
    await storage.persistSession('updated');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sdk-test-key'), 'updated');
    expect(prefs.getString('other'), 'safe');
  });
}
