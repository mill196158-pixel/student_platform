import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();
  final requests = <Uri>[];
  bool failRequests = false;

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(params.uri);
    if (failRequests) throw PlatformException(code: 'load_failed');
  }

  @override
  Future<void> runJavaScript(String script) async =>
      throw PlatformException(code: 'view_closed');
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {}
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();
  late WebResourceErrorCallback report;
  late PageEventCallback finished;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async =>
      report = callback;
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      finished = callback;
}

class _View extends PlatformWebViewWidget {
  _View(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const Text('Platform map');
}

class _MapPlatform extends WebViewPlatform {
  bool failInitialLoad = false;
  late _Delegate delegate;
  late _Controller controller;

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      delegate = _Delegate(params);
  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      controller = _Controller(params)..failRequests = failInitialLoad;
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
          PlatformWebViewWidgetCreationParams params) =>
      _View(params);
}

void main() {
  testWidgets('first native load failure can be retried', (tester) async {
    final platform = _MapPlatform()..failInitialLoad = true;
    WebViewPlatform.instance = platform;
    await tester.pumpWidget(const MaterialApp(home: MapSpbgasuScreen()));
    await tester.pump();
    expect(find.text('Не удалось загрузить карту'), findsOneWidget);
    platform.controller.failRequests = false;
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    expect(platform.controller.requests.length, 2);
    expect(find.text('Platform map'), findsOneWidget);
  });

  testWidgets(
      'only a main-frame failure replaces the map and retry opens the map URL',
      (tester) async {
    final platform = _MapPlatform();
    WebViewPlatform.instance = platform;
    await tester.pumpWidget(const MaterialApp(home: MapSpbgasuScreen()));
    await tester.pump();
    final mapUrl = Uri.parse('https://map.spbgasu.ru/');
    expect(platform.controller.requests, [mapUrl]);

    for (final mainFrame in [false, true]) {
      platform.delegate.report(WebResourceError(
          errorCode: -2, description: 'offline', isForMainFrame: mainFrame));
      await tester.pump();
      expect(
          find.text('Platform map'), mainFrame ? findsNothing : findsOneWidget);
      expect(find.text('Повторить'), mainFrame ? findsOneWidget : findsNothing);
    }
    platform.controller.failRequests = true;
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    expect(platform.controller.requests, [mapUrl, mapUrl]);
    expect(find.text('Повторить'), findsOneWidget);
    platform.controller.failRequests = false;
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    expect(platform.controller.requests, [mapUrl, mapUrl, mapUrl]);
    platform.delegate.finished(mapUrl.toString());
    await tester.pump();
    expect(find.text('Platform map'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
