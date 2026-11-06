import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';

void main() {
  testWidgets('closed barrier never starts profile request', (tester) async {
    var calls = 0;
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true)
      ..close();
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
      peerId: 'peer',
      peerName: '',
      onlineBarrier: barrier,
      sessionIsCurrent: () => true,
      debugResolveProfile: (_) async {
        calls++;
        return (name: 'Name', avatar: null);
      },
      debugChatBuilder: (_, title) => Text(title),
    )));
    expect(calls, 0);
  });

  testWidgets('late profile is fenced after same-owner session ABA and drains',
      (tester) async {
    var generation = 1;
    final captured = generation;
    final barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => generation == captured);
    final response = Completer<({String name, String? avatar})>();
    await tester.pumpWidget(MaterialApp(
        home: DirectChatScreen(
      peerId: 'peer',
      peerName: '',
      onlineBarrier: barrier,
      sessionIsCurrent: () => generation == captured,
      debugResolveProfile: (_) => response.future,
      debugChatBuilder: (_, title) => Text(title),
    )));
    expect(barrier.activeCount, 1);
    generation = 2;
    barrier.close();
    generation = 3;
    response.complete((name: 'Old private name', avatar: null));
    await tester.pump();
    expect(find.text('Old private name'), findsNothing);
    expect(await barrier.closeAndDrain(timeout: const Duration(seconds: 1)),
        isTrue);
  });

  testWidgets('late result for old peer does not replace new peer',
      (tester) async {
    final first = Completer<({String name, String? avatar})>();
    final second = Completer<({String name, String? avatar})>();
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    bool current() => true;
    Future<({String name, String? avatar})> fetch(String peer) =>
        peer == 'a' ? first.future : second.future;
    Widget page(String peer) => MaterialApp(
            home: DirectChatScreen(
          peerId: peer,
          peerName: '',
          onlineBarrier: barrier,
          sessionIsCurrent: current,
          debugResolveProfile: fetch,
          debugChatBuilder: (_, title) => Text(title),
        ));
    await tester.pumpWidget(page('a'));
    await tester.pumpWidget(page('b'));
    first.complete((name: 'Old peer', avatar: null));
    await tester.pump();
    expect(find.text('Old peer'), findsNothing);
    second.complete((name: 'New peer', avatar: null));
    await tester.pump();
    await tester.pump();
    expect(find.text('New peer'), findsOneWidget);
  });
}
