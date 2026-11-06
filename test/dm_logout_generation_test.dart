import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';

void main() {
  test('late cleanup of A leaves B generation state intact', () async {
    final entered = Completer<void>();
    final resume = Completer<void>();
    DmApi.debugPrimeClearedAt('same-chat', DateTime.utc(2026, 1));
    DmApi.debugAfterSessionDetach = () async {
      entered.complete();
      await resume.future;
    };
    addTearDown(() => DmApi.debugAfterSessionDetach = null);
    final cleanup = DmApi.clearSessionState();
    await entered.future;
    final newFloor = DateTime.utc(2026, 2);
    DmApi.debugPrimeClearedAt('same-chat', newFloor);
    resume.complete();
    await cleanup;
    expect(DmApi.debugCachedClearedAt('same-chat'), newFloor);
  });
}
