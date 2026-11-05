import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('late news write never lands in another account cache', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    var user = 'a';
    final cache =
        PublishedNewsCache(prefs: () => gate.future, currentUserId: () => user);
    final write = cache.write([
      {'id': 'news-a'}
    ]);
    user = 'b';
    gate.complete(prefs);
    await write;
    expect(prefs.getString('${PublishedNewsCache.keyPrefix}__a'), isNull);
    expect(prefs.getString('${PublishedNewsCache.keyPrefix}__b'), isNull);
  });

  test('late news write from a previous session of same user is ignored',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    var valid = true;
    final cache =
        PublishedNewsCache(prefs: () => gate.future, currentUserId: () => 'a');
    final write = cache.write([
      {'id': 'old'}
    ], owner: 'a', isCurrent: () => valid);
    valid = false;
    gate.complete(prefs);
    await write;
    expect(prefs.getString('${PublishedNewsCache.keyPrefix}__a'), isNull);
  });
}
