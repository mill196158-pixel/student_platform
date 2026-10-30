import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';

class Dashboard implements HomeDashboardService {
  final pending = Completer<HomeDashboardData>();
  @override
  Future<HomeDashboardData> load() => pending.future;
  @override
  Future<List<HomeNewsItem>> loadCachedNews() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Notifications implements AppNotificationsApi {
  final pending = Completer<int>();
  @override
  Future<int> unreadCount() => pending.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Promo implements HomePromoService {
  final pending = Completer<HomePromoLoadResult>();
  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) => pending.future;
  @override
  Future<HomePromoLoadResult> loadCached() async => HomePromoLoadResult(cards: [
        ManagedContentCard.tryParseHomePromo({
          'id': 'cached',
          'template_key': 'home_promo_v1',
          'schema_version': 2,
          'placement': 'home_promo',
          'sort_order': 0,
          'priority': 0,
          'origin': 'admin',
          'payload': {
            'title': 'Cached promo',
            'subtitle': 'Subtitle',
            'icon_key': 'psychology',
            'gradient_colors': ['#FFFBFF', '#F3EEF9'],
            'cta_label': 'Open',
            'cta_route': '/my-diary',
            'dismissible': true,
            'card_variant': 'image_full',
            'image_asset_id': 'image-a',
            'home_slot': 'top'
          },
        })!,
      ]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Media implements ContentMediaService {
  final requested = <String>[];
  @override
  Future<Uint8List?> fetchBytes(String id, {String? contentVersion}) async {
    requested.add(id);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'cached promo hydration does not wait for dashboard, badge or promo RPC',
      (t) async {
    final dashboard = Dashboard();
    final notifications = Notifications();
    final promo = Promo();
    final media = Media();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            notificationsApi: notifications,
            promoService: promo,
            contentMedia: media)));
    await t.pump();
    await t.pump();
    expect(media.requested, contains('image-a'));
    expect(dashboard.pending.isCompleted, isFalse);
    expect(notifications.pending.isCompleted, isFalse);
    expect(promo.pending.isCompleted, isFalse);
    dashboard.pending.completeError(StateError('offline dashboard'));
    notifications.pending.complete(0);
    promo.pending.complete(const HomePromoLoadResult(intentionallyEmpty: true));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
