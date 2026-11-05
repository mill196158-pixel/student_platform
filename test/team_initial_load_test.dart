import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/state/team_initial_load.dart';

void main() {
  test('chat starts while assignments restore; assignment subscription waits',
      () async {
    final restore = Completer<void>();
    final events = <String>[];
    final work = runTeamInitialLoad(
      isClosed: () => false,
      restoreAssignments: () async {
        events.add('restore-start');
        await restore.future;
        events.add('restored');
      },
      resolveChat: () async {
        events.add('resolve');
        return 'chat';
      },
      hydrateChat: (id) async {
        events.add('hydrate:$id');
      },
      startChat: (id) => events.add('chat:$id'),
      startRole: () => events.add('role'),
      subscribeChat: () => events.add('chat-sub'),
      startAssignments: () => events.add('assignments'),
      subscribeAssignments: () => events.add('assignment-sub'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, [
      'restore-start',
      'resolve',
      'hydrate:chat',
      'chat:chat',
      'role',
      'chat-sub'
    ]);
    restore.complete();
    await work;
    expect(events, [
      'restore-start',
      'resolve',
      'hydrate:chat',
      'chat:chat',
      'role',
      'chat-sub',
      'restored',
      'assignments',
      'assignment-sub'
    ]);
  });

  test('failed assignment restore does not stop chat or fresh assignments',
      () async {
    final events = <String>[];
    await runTeamInitialLoad(
      isClosed: () => false,
      restoreAssignments: () async => throw StateError('cache failed'),
      resolveChat: () async => 'chat',
      hydrateChat: (_) async => events.add('hydrated'),
      startChat: (_) => events.add('chat'),
      startRole: () {},
      subscribeChat: () {},
      startAssignments: () => events.add('assignments'),
      subscribeAssignments: () => events.add('assignment-sub'),
    );
    expect(events, ['hydrated', 'chat', 'assignments', 'assignment-sub']);
  });

  for (final waitingOn in ['resolve', 'hydrate', 'restore']) {
    test('closing during $waitingOn starts no later work', () async {
      final gate = Completer<void>();
      var closed = false;
      final events = <String>[];
      final work = runTeamInitialLoad(
        isClosed: () => closed,
        restoreAssignments: () async {
          if (waitingOn == 'restore') await gate.future;
        },
        resolveChat: () async {
          if (waitingOn == 'resolve') await gate.future;
          return 'chat';
        },
        hydrateChat: (_) async {
          if (waitingOn == 'hydrate') await gate.future;
        },
        startChat: (_) => events.add('chat'),
        startRole: () => events.add('role'),
        subscribeChat: () => events.add('chat-sub'),
        startAssignments: () => events.add('assignments'),
        subscribeAssignments: () => events.add('assignment-sub'),
      );
      await Future<void>.delayed(Duration.zero);
      final before = List<String>.of(events);
      closed = true;
      gate.complete();
      await work;
      expect(events, before);
    });
  }
}
