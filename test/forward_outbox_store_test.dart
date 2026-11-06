import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

class Storage implements ForwardOutboxStorage {
  final values = <String, String>{};
  final failures = <String>[];
  int calls = 0;
  Completer<void>? readEntered, readRelease;
  Completer<void>? writeEntered, writeRelease, removeEntered, removeRelease;
  bool fail(String operation) {
    if (failures.isEmpty || failures.first != operation) return false;
    failures.removeAt(0);
    return true;
  }

  @override
  Future<String?> read(String key) async {
    calls++;
    readEntered?.complete();
    await readRelease?.future;
    if (fail('read')) throw StateError('read');
    return values[key];
  }

  @override
  Future<bool> write(String key, String value) async {
    calls++;
    writeEntered?.complete();
    await writeRelease?.future;
    values[key] = value;
    if (fail('write-throw')) throw StateError('write');
    return !fail('write-false');
  }

  @override
  Future<bool> remove(String key) async {
    calls++;
    removeEntered?.complete();
    await removeRelease?.future;
    values.remove(key);
    if (fail('remove-throw')) throw StateError('remove');
    return !fail('remove-false');
  }
}

void main() {
  late StreamController<AuthState> events;
  late Session session;
  late AuthSessionScope scope;
  late Storage storage;
  late ForwardOutboxStore store;
  setUp(() {
    events = StreamController<AuthState>.broadcast(sync: true);
    session = fakeSession('a');
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    storage = Storage();
    store = ForwardOutboxStore(scope, ForwardOutboxCoordinator(storage));
  });
  tearDown(() async {
    scope.dispose();
    await events.close();
  });

  test('replacement and same payload invalidate old receipt', () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'one');
    final first = (await store.peek(owner, 'chat'))!;
    await store.put(owner, 'chat', text: 'one');
    expect(await store.acknowledge(first), ForwardAcknowledgeResult.changed);
    final second = (await store.peek(owner, 'chat'))!;
    expect(second.text, 'one');
    expect(await store.acknowledge(second), ForwardAcknowledgeResult.removed);
    expect(await store.acknowledge(second), ForwardAcknowledgeResult.changed);
  });
  test('vacant reservation preserves previous and unreadable entries',
      () async {
    final owner = scope.capture()!;
    await store.putIfVacant(owner, 'chat', text: 'first', files: ['f']);
    final original = storage.values['forward_outbox_a_chat'];
    await expectLater(store.putIfVacant(owner, 'chat', text: 'second'),
        throwsA(isA<ForwardOutboxOccupied>()));
    expect(storage.values['forward_outbox_a_chat'], original);
    expect((await store.peek(owner, 'chat'))?.text, 'first');
    storage.values['forward_outbox_a_chat'] = '{broken';
    await expectLater(store.putIfVacant(owner, 'chat', text: 'second'),
        throwsA(isA<ForwardOutboxOccupied>()));
    expect(storage.values['forward_outbox_a_chat'], '{broken');
  });

  test('concurrent reservations cannot overwrite the winning entry', () async {
    final owner = scope.capture()!;
    final first = store.putIfVacant(owner, 'chat', text: 'first');
    final second = store.putIfVacant(owner, 'chat', text: 'second');
    final rejected = expectLater(second, throwsA(isA<ForwardOutboxOccupied>()));
    await first;
    await rejected;
    expect((await store.peek(owner, 'chat'))?.text, 'first');
  });

  test('a new store sees and preserves an unfinished reservation', () async {
    final owner = scope.capture()!;
    await store.putIfVacant(owner, 'chat', text: 'pending', files: ['f']);
    store.dispose();
    store = ForwardOutboxStore(scope, ForwardOutboxCoordinator(storage));
    final restored = await store.peek(owner, 'chat');
    expect(restored?.text, 'pending');
    expect(restored?.files, ['f']);
    await expectLater(store.putIfVacant(owner, 'chat', text: 'replacement'),
        throwsA(isA<ForwardOutboxOccupied>()));
    expect((await store.peek(owner, 'chat'))?.text, 'pending');
  });

  test('vacant reservation copies input lists before delayed read', () async {
    final owner = scope.capture()!;
    storage.readEntered = Completer<void>();
    storage.readRelease = Completer<void>();
    final files = ['original-url'];
    final ids = ['original-id'];
    final put = store.putIfVacant(owner, 'chat',
        text: 'pending', files: files, fileIds: ids);
    await storage.readEntered!.future;
    files[0] = 'changed-url';
    ids[0] = 'changed-id';
    storage.readRelease!.complete();
    storage.readEntered = null;
    storage.readRelease = null;
    await put;
    final restored = (await store.peek(owner, 'chat'))!;
    expect(restored.files, ['original-url']);
    expect(restored.fileIds, ['original-id']);
  });

  for (final failure in ['write-false', 'write-throw']) {
    test('vacant $failure restores missing slot', () async {
      final owner = scope.capture()!;
      storage.failures.add(failure);
      await expectLater(store.putIfVacant(owner, 'chat', text: 'pending'),
          throwsA(isA<ForwardOutboxStorageFailure>()));
      expect(storage.values.containsKey('forward_outbox_a_chat'), isFalse);
      expect(await store.peek(owner, 'chat'), isNull);
    });
  }

  for (final failure in ['remove-false', 'remove-throw']) {
    test('vacant rollback $failure quarantines only the affected chat',
        () async {
      final owner = scope.capture()!;
      storage.failures.addAll(['write-false', failure]);
      await expectLater(store.putIfVacant(owner, 'chat', text: 'pending'),
          throwsA(isA<ForwardOutboxStorageFailure>()));
      await expectLater(store.peek(owner, 'chat'),
          throwsA(isA<ForwardOutboxStorageFailure>()));
      final replacement = ForwardOutboxStore(scope, store.coordinator);
      await expectLater(replacement.peek(owner, 'chat'),
          throwsA(isA<ForwardOutboxStorageFailure>()));
      await replacement.putIfVacant(owner, 'other', text: 'safe');
      expect((await replacement.peek(owner, 'other'))?.text, 'safe');
      replacement.dispose();
    });
  }

  for (final operation in ['session change', 'dispose']) {
    test('vacant write rolls back on $operation', () async {
      final owner = scope.capture()!;
      storage.writeEntered = Completer<void>();
      storage.writeRelease = Completer<void>();
      final put = store.putIfVacant(owner, 'chat', text: 'pending');
      final rejected = expectLater(put, throwsA(isA<StateError>()));
      await storage.writeEntered!.future;
      if (operation == 'dispose') {
        store.dispose();
      } else {
        session = fakeSession('b');
        events.add(AuthState(AuthChangeEvent.signedIn, session));
      }
      storage.writeRelease!.complete();
      storage.writeEntered = null;
      storage.writeRelease = null;
      await rejected;
      expect(storage.values.containsKey('forward_outbox_a_chat'), isFalse);
      expect(storage.values.containsKey('forward_outbox_b_chat'), isFalse);
    });
  }
  test('legacy read is non-destructive and invalid data stays intact',
      () async {
    final owner = scope.capture()!;
    const key = 'forward_outbox_a_chat';
    for (final value in [
      '{broken',
      '{}',
      '{"text":42}',
      '{"version":"unknown","text":"x"}',
      '{"text":"__FG__:{broken"}'
    ]) {
      storage.values[key] = value;
      expect(await store.peek(owner, 'chat'), isNull);
      expect(storage.values[key], value);
    }
    storage.values[key] = '{"text":"legacy","files":["a"]}';
    final legacy = (await store.peek(owner, 'chat'))!;
    expect(legacy.files, ['a']);
    expect(storage.values[key], '{"text":"legacy","files":["a"]}');
    expect(() => legacy.files.add('b'), throwsUnsupportedError);
  });
  for (final failure in [
    'write-false',
    'write-throw',
    'remove-false',
    'remove-throw'
  ]) {
    test('$failure restores the previous bytes', () async {
      final owner = scope.capture()!;
      await store.put(owner, 'chat', text: 'old');
      final entry = (await store.peek(owner, 'chat'))!;
      final before = storage.values.values.single;
      storage.failures.add(failure);
      await expectLater(
          failure.startsWith('write')
              ? store.put(owner, 'chat', text: 'new')
              : store.acknowledge(entry),
          throwsA(isA<ForwardOutboxStorageFailure>()));
      expect(storage.values.values.single, before);
      expect((await store.peek(owner, 'chat'))!.text, 'old');
    });
  }
  test('failed recovery quarantines the key but leaves other chat usable',
      () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'old');
    storage.failures.addAll(['write-false', 'write-false']);
    await expectLater(store.put(owner, 'chat', text: 'new'),
        throwsA(isA<ForwardOutboxStorageFailure>()));
    await expectLater(
        store.peek(owner, 'chat'), throwsA(isA<ForwardOutboxStorageFailure>()));
    await store.put(owner, 'other', text: 'safe');
    expect((await store.peek(owner, 'other'))!.text, 'safe');
  });
  test('session change during remove restores old account data', () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'saved');
    final entry = (await store.peek(owner, 'chat'))!;
    storage.removeEntered = Completer();
    storage.removeRelease = Completer();
    final ack = store.acknowledge(entry);
    await storage.removeEntered!.future;
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    storage.removeRelease!.complete();
    await expectLater(ack, throwsStateError);
    expect(storage.values.values.single, contains('saved'));
  });

  test('queued replacement cannot be removed by prior receipt', () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'old');
    final old = (await store.peek(owner, 'chat'))!;
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final replacement = store.put(owner, 'chat', text: 'new');
    await storage.writeEntered!.future;
    final ack = store.acknowledge(old);
    storage.writeRelease!.complete();
    await replacement;
    expect(await ack, ForwardAcknowledgeResult.changed);
    expect((await store.peek(owner, 'chat'))!.text, 'new');
  });

  test('foreign receipt and externally missing record never remove data',
      () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'saved');
    final entry = (await store.peek(owner, 'chat'))!;
    final other = ForwardOutboxStore(scope, ForwardOutboxCoordinator(storage));
    expect(await other.acknowledge(entry), ForwardAcknowledgeResult.changed);
    storage.values.clear();
    expect(await store.acknowledge(entry), ForwardAcknowledgeResult.missing);
  });

  test('read errors are typed and the queue remains usable', () async {
    final owner = scope.capture()!;
    storage.failures.add('read');
    await expectLater(
        store.peek(owner, 'chat'), throwsA(isA<ForwardOutboxStorageFailure>()));
    await store.put(owner, 'chat', text: 'safe');
    expect((await store.peek(owner, 'chat'))!.text, 'safe');
  });

  test('old account receipt is invalid after A to B to A', () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'safe');
    final entry = (await store.peek(owner, 'chat'))!;
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await expectLater(store.acknowledge(entry), throwsStateError);
    expect((await store.peek(scope.capture()!, 'chat'))!.text, 'safe');
  });

  test('legacy ABA after coordinated mutation cannot reuse old receipt',
      () async {
    final owner = scope.capture()!;
    const key = 'forward_outbox_a_chat';
    const raw = '{"text":"legacy"}';
    storage.values[key] = raw;
    final entry = (await store.peek(owner, 'chat'))!;
    await store.put(owner, 'chat', text: 'replacement');
    storage.values[key] = raw;
    expect(await store.acknowledge(entry), ForwardAcknowledgeResult.changed);
    expect(storage.values[key], raw);
  });

  test('changed session during write restores previous record', () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'old');
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = store.put(owner, 'chat', text: 'new');
    await storage.writeEntered!.future;
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    await expectLater(pending, throwsStateError);
    expect(storage.values.values.single, contains('old'));
  });

  test('disposing store during a write rolls back and prevents further access',
      () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'old');
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = store.put(owner, 'chat', text: 'new');
    await storage.writeEntered!.future;
    store.dispose();
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    await expectLater(pending, throwsStateError);
    expect(storage.values.values.single, contains('old'));
    await expectLater(store.peek(owner, 'chat'), throwsStateError);
  });

  test('disposed reader cannot return a delayed snapshot', () async {
    final owner = scope.capture()!;
    await store.put(owner, 'chat', text: 'saved');
    storage.readEntered = Completer();
    storage.readRelease = Completer();
    final pending = store.peek(owner, 'chat');
    await storage.readEntered!.future;
    store.dispose();
    storage.readEntered = null;
    storage.readRelease!.complete();
    await expectLater(pending, throwsStateError);
    expect(storage.values.values.single, contains('saved'));
  });

  test('disposed acknowledgement restores before replacement store writes',
      () async {
    final owner = scope.capture()!;
    final shared = ForwardOutboxCoordinator(storage);
    final old = ForwardOutboxStore(scope, shared);
    final fresh = ForwardOutboxStore(scope, shared);
    await old.put(owner, 'chat', text: 'old');
    final entry = (await old.peek(owner, 'chat'))!;
    storage.removeEntered = Completer();
    storage.removeRelease = Completer();
    final pending = old.acknowledge(entry);
    await storage.removeEntered!.future;
    old.dispose();
    final replacement = fresh.put(owner, 'chat', text: 'fresh');
    storage.removeEntered = null;
    storage.removeRelease!.complete();
    await expectLater(pending, throwsStateError);
    await replacement;
    expect((await fresh.peek(owner, 'chat'))!.text, 'fresh');
  });

  test('failed rollback quarantines key for replacement store as well',
      () async {
    final owner = scope.capture()!;
    final shared = ForwardOutboxCoordinator(storage);
    final old = ForwardOutboxStore(scope, shared);
    final fresh = ForwardOutboxStore(scope, shared);
    await old.put(owner, 'chat', text: 'old');
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = old.put(owner, 'chat', text: 'new');
    await storage.writeEntered!.future;
    old.dispose();
    storage.failures.addAll(['write-false', 'write-false']);
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    await expectLater(pending, throwsA(isA<ForwardOutboxStorageFailure>()));
    await expectLater(
        fresh.peek(owner, 'chat'), throwsA(isA<ForwardOutboxStorageFailure>()));
  });
}
