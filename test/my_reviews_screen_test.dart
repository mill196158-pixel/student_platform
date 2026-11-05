import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/profile/my_reviews_screen.dart';
import 'package:student_platform/src/ui/profile/student_review_service.dart';

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
    expect(find.text('Не удалось загрузить отзывы'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
