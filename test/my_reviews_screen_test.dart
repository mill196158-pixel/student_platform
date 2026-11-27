import 'package:student_ui/student_ui.dart'
    show ProductLoadingIndicator, ProductTheme, StudentReviewCard;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/profile/my_reviews_screen.dart';
import 'package:student_platform/src/ui/profile/student_review_service.dart';
import 'package:student_platform/src/ui/info/entity_review_screen.dart';

class RecoveringRpc implements StudentReviewRpcClient {
  int calls = 0;
  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    if (++calls == 1) {
      throw const PostgrestException(message: 'server failure', code: '42703');
    }
    return <dynamic>[];
  }
}

class _ReviewsRpc implements StudentReviewRpcClient {
  static const entityLabel =
      'Надёжность систем водоснабжения и водоотведения для объектов городской инфраструктуры';
  static const body = 'На примерах удалось разобраться в расчётах.';
  static const reason = 'Уберите из текста номер учебной группы.';
  static const entityId = 'subject-1';

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    if (function != 'get_my_entity_reviews') return null;
    return [
      {
        'review_id': 'review-1',
        'entity_type': 'subject',
        'entity_id': entityId,
        'entity_label': entityLabel,
        'tag_scores': {'usefulness': 5},
        'moderation_status': 'rejected',
        'moderation_reason': reason,
        'body_text': body,
      },
    ];
  }
}

void main() {
  testWidgets(
      'server failure offers retry and recovers without false empty state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final rpc = RecoveringRpc();
    final service =
        StudentReviewService(rpcClient: rpc, currentUserId: () => 'test-user');
    await tester
        .pumpWidget(MaterialApp(home: MyReviewsScreen(reviewService: service)));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить отзывы'), findsOneWidget);
    expect(find.text('Вы ещё не оставляли отзывов'), findsNothing);
    expect(find.byType(ProductLoadingIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(rpc.calls, 2);
    expect(find.text('Вы ещё не оставляли отзывов'), findsOneWidget);
    expect(find.text('Отзывы проходят проверку перед публикацией.'),
        findsOneWidget);
    expect(find.textContaining('балл'), findsNothing);
    expect(find.text('Не удалось загрузить отзывы'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reviews show readable status and keep their open action in a narrow dark layout',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final service = StudentReviewService(
      rpcClient: _ReviewsRpc(),
      currentUserId: () => 'test-user',
    );
    final dark = ProductTheme.build(brightness: Brightness.dark);
    await tester.pumpWidget(MaterialApp(
      theme: dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.5)),
        child: child!,
      ),
      home: MyReviewsScreen(reviewService: service),
    ));
    await tester.pumpAndSettle();
    final card = find.byType(StudentReviewCard);
    final material = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Material && widget.color == dark.colorScheme.surface,
      ),
    );
    expect(material, findsOneWidget);
    expect(find.text('Предмет'), findsOneWidget);
    expect(find.text(_ReviewsRpc.entityLabel), findsOneWidget);
    expect(find.text('Отклонён'), findsOneWidget);
    expect(find.text('Полезность: 5'), findsOneWidget);
    expect(find.text(_ReviewsRpc.body), findsOneWidget);
    expect(
      find.text('Комментарий модератора: ${_ReviewsRpc.reason}'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(_ReviewsRpc.entityLabel));
    await tester.pumpAndSettle();
    final detail =
        tester.widget<EntityReviewScreen>(find.byType(EntityReviewScreen));
    expect(detail.entityId, _ReviewsRpc.entityId);
    expect(detail.reviewService, same(service));
    expect(tester.takeException(), isNull);
  });
}
