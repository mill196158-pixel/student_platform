import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/notifications/in_app_toast_host.dart';

void main() {
  testWidgets(
      'global banner survives route change but clears on read and logout',
      (t) async {
    final bus = InAppNotificationBus.instance;
    await t.pumpWidget(MaterialApp(
        builder: (_, child) => InAppToastHost(child: child!),
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) =>
                            const Scaffold(body: Text('Profile fixture')))),
                    child: const Text('Profile'))))));
    await t.tap(find.text('Profile'));
    await t.pumpAndSettle();
    void send(String id) => bus.emit(InAppNotificationEvent(
        type: 'dm_message',
        title: 'Synthetic sender',
        body: 'Test message',
        payload:
            PushPayload(version: 1, type: 'dm_message', notificationId: id)));
    send('one');
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
    expect(find.text('Synthetic sender'), findsOneWidget);
    bus.dismissNotifications({'other'});
    await t.pump();
    await t.pump();
    expect(find.text('Synthetic sender'), findsOneWidget);
    bus.dismissNotifications({'one'});
    await t.pump();
    await t.pump();
    expect(find.text('Synthetic sender'), findsNothing);
    send('one');
    await t.pumpAndSettle();
    expect(find.text('Synthetic sender'), findsNothing,
        reason: 'late duplicate after read must remain dismissed');
    bus.emit(const InAppNotificationEvent(type: 'friend_accepted',
        title: 'Friend accepted fixture', body: 'Accepted',
        payload: PushPayload(version: 1, type: 'friend_accepted', notificationId: 'friend')));
    await t.pumpAndSettle();
    expect(find.text('Friend accepted fixture'), findsOneWidget);
    bus.dismissNotifications({'friend'});
    await t.pumpAndSettle();
    send('two');
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
    expect(find.text('Synthetic sender'), findsOneWidget);
    bus.resetSession();
    await t.pump();
    await t.pump();
    expect(find.text('Synthetic sender'), findsNothing);
    send('two');
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
    expect(find.text('Synthetic sender'), findsOneWidget,
        reason: 'dedupe cannot leak across accounts');
    await t.tap(find.text('Synthetic sender'));
    await t.pump(const Duration(milliseconds: 50));
    bus.resetSession();
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Synthetic sender'), findsNothing);
    send('three');
    await t.pump();
    await t.pump();
    await t.pumpAndSettle();
    await t.tap(find.text('Synthetic sender'));
    await t.pump(const Duration(milliseconds: 50));
    send('four');
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Synthetic sender'), findsOneWidget,
        reason: 'cancelled old dismiss must not clear new banner');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
