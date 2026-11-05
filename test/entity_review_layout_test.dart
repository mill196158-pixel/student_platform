import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/entity_review_screen.dart';
import 'package:student_platform/src/ui/profile/student_review_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _ReviewRpc implements StudentReviewRpcClient {
  _ReviewRpc({this.failFirst = false});
  final bool failFirst;
  int reads = 0;
  final submits = <Map<String, dynamic>>[];
  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    if (function == 'get_entity_review_summary') {
      reads++;
      if (failFirst && reads == 1) {
        throw const PostgrestException(
            message: 'temporarily unavailable', code: '42703');
      }
      return {
        'entity_type': 'subject',
        'entity_id': 'subject-1',
        'active_count': 0,
        'tag_averages': {},
        'structured_enabled': true
      };
    }
    if (function == 'submit_my_entity_review') {
      submits.add(params!);
      return {
        'ok': true,
        'review_id': 'review-1',
        'moderation_status': 'pending'
      };
    }
    throw StateError('Unexpected RPC $function');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Widget app(_ReviewRpc rpc,
          {Brightness brightness = Brightness.light,
          double scale = 1,
          double keyboard = 0,
          Size size = const Size(390, 844)}) =>
      MaterialApp(
          theme: ProductTheme.build(brightness: brightness),
          home: MediaQuery(
              data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                  viewInsets: EdgeInsets.only(bottom: keyboard)),
              child: EntityReviewScreen(
                  entityType: ReviewEntityType.subject,
                  entityId: 'subject-1',
                  entityLabel:
                      'Системы и сооружения водоснабжения и водоотведения',
                  reviewService: StudentReviewService(
                      rpcClient: rpc, currentUserId: () => 'user-1'))));

  testWidgets('summary failure ends loading, hides submit and retry recovers',
      (tester) async {
    final rpc = _ReviewRpc(failFirst: true);
    await tester.pumpWidget(app(rpc));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить отзыв'), findsOneWidget);
    expect(find.byType(ProductLoadingIndicator), findsNothing);
    expect(find.text('Отправить отзыв'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(rpc.reads, 2);
    expect(find.text('Отправить отзыв'), findsOneWidget);
    expect(rpc.submits, isEmpty);
  });

  testWidgets(
      'scores are explicit, cancel preserves draft and reset omits tag from submit',
      (tester) async {
    final rpc = _ReviewRpc();
    await tester.pumpWidget(app(rpc));
    await tester.pumpAndSettle();
    Future<void> select(String label, String value) async {
      await tester
          .tap(find.widgetWithText(DropdownButtonFormField<int>, label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(value).hitTestable().last);
      await tester.pumpAndSettle();
    }

    await select('Полезность', '1 из 5');
    await tester
        .tap(find.widgetWithText(DropdownButtonFormField<int>, 'Полезность'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-score-Полезность-1')),
        findsOneWidget);
    await select('Полезность', '5 из 5');
    await select('Нагрузка', '2 из 5');
    await select('Полезность', 'Не оценивать');
    expect(rpc.submits, isEmpty);
    await tester.tap(find.text('Отправить отзыв'));
    await tester.pumpAndSettle();
    expect(rpc.submits, hasLength(1));
    expect(rpc.submits.single['p_tag_scores'], {'workload': 2});
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets('review form fits $size dark=$dark with text and keyboard',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final rpc = _ReviewRpc();
        await tester.pumpWidget(app(rpc,
            size: size,
            brightness: dark ? Brightness.dark : Brightness.light,
            scale: 1.5,
            keyboard: 240));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(ListView)).width,
            lessThanOrEqualTo(680));
        final submit = find.widgetWithText(FilledButton, 'Отправить отзыв');
        await tester.scrollUntilVisible(submit, 160,
            scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(submit);
        await tester.pumpAndSettle();
        expect(submit.hitTestable(), findsOneWidget);
        expect(
            tester.getRect(submit).bottom,
            lessThanOrEqualTo(
                tester.getRect(find.byType(ListView)).bottom + 1));
        expect(rpc.submits, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
