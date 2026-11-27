import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

const _coverColor = Color(0xFF2A9D8F);

Future<Uint8List> _cover() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(_coverColor, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(96, 80);
  picture.dispose();
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<Color> _framePixel(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Offset position,
  String label,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final local = boundary.globalToLocal(position);
  final image = boundary.toImageSync();
  try {
    final color = await tester.runAsync(() async {
      final pixels = (await image.toByteData())!;
      final index = (local.dy.floor() * image.width + local.dx.floor()) * 4;
      final path = Platform.environment['STUDENT_HOME_NEWS_CAPTURE_DIR'];
      if (path != null) {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$path/$label.png').writeAsBytes(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      }
      return Color.fromARGB(
        pixels.getUint8(index + 3),
        pixels.getUint8(index),
        pixels.getUint8(index + 1),
        pixels.getUint8(index + 2),
      );
    });
    return color!;
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final text = FontLoader('packages/student_ui/WorkspaceSans')
      ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), icons.load()]);
  });

  testWidgets('cached cover is colored on the first Home frame and tab return',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = (await tester.runAsync(_cover))!;
    final publication = StudentHomeNews(
      id: 'cached-news',
      title: 'Сохранённая публикация',
      subtitle: '',
      body: 'Тестовая публикация',
      icon: Icons.newspaper,
      gradientColors: const [Color(0xFFE0E0E0), Color(0xFFBDBDBD)],
      variant: StudentHomeNewsVariant.imageOnly,
      imageBytes: bytes,
    );
    final data = StudentHomeData(
      profile: const StudentHomeProfile(name: 'Студент', groupName: 'QA'),
      currentDate: DateTime(2026, 11, 27),
      lessons: const [],
      assignments: const [],
      news: [publication],
    );
    final boundary = GlobalKey();
    late BuildContext warmContext;
    var selected = 1;
    var visit = 0;
    await tester.pumpWidget(MaterialApp(
      theme: studentPlatformLightTheme(),
      home: Builder(builder: (context) {
        warmContext = context;
        return StatefulBuilder(builder: (context, update) {
          return RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: selected == 0
                  ? StudentHomeView(
                      data: data,
                      contentLayoutVisit: visit,
                      hideHomePromo: true)
                  : const Center(child: Text('Другая вкладка')),
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: selected,
                onTap: (index) => update(() {
                  selected = index;
                  if (index == 0) visit++;
                }),
                items: const [
                  BottomNavigationBarItem(
                      icon: Icon(Icons.home), label: 'Главная'),
                  BottomNavigationBarItem(
                      icon: Icon(Icons.person), label: 'Профиль'),
                ],
              ),
            ),
          );
        });
      }),
    ));
    final provider = MemoryImage(bytes);
    await tester.runAsync(() => precacheImage(provider, warmContext));
    expect(
        (await provider.obtainCacheStatus(
                configuration: ImageConfiguration.empty))
            ?.live,
        isTrue);

    Future<Color> openHome(String label) async {
      await tester.tap(find.text('Главная'));
      await tester.pump();
      final card = find.byType(StudentHomeNewsCard);
      expect(card, findsOneWidget);
      return _framePixel(tester, boundary, tester.getCenter(card), label);
    }

    final first = await openHome('first-home-frame');
    await tester.tap(find.text('Профиль'));
    await tester.pump();
    final returned = await openHome('return-home-frame');
    expect([first, returned], [_coverColor, _coverColor]);
  });

  testWidgets('uses the exact warmed cover provider and clears it on removal',
      (tester) async {
    final bytes = (await tester.runAsync(_cover))!;
    final provider = ResizeImage(MemoryImage(bytes), width: 64);
    final publication = StudentHomeNews(
      id: 'prepared',
      title: 'Заголовок',
      subtitle: '',
      body: '',
      icon: Icons.newspaper,
      gradientColors: const [Colors.grey, Colors.grey],
      variant: StudentHomeNewsVariant.imageOnly,
      imageBytes: bytes,
      imageProvider: provider,
    );
    final boundary = GlobalKey();
    late BuildContext warmContext;
    Widget app([StudentHomeNews? item]) => MaterialApp(
          home: Builder(builder: (context) {
            warmContext = context;
            return RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: item == null
                    ? null
                    : Center(child: StudentHomeNewsCard(item: item)),
              ),
            );
          }),
        );

    await tester.pumpWidget(app());
    await tester.runAsync(() => precacheImage(provider, warmContext));
    final card = find.byType(StudentHomeNewsCard);
    Future<Color> pixel(String label) =>
        _framePixel(tester, boundary, tester.getCenter(card), label);
    await tester.pumpWidget(app(publication));
    expect(tester.widget<Image>(find.byType(Image)).image, same(provider));
    expect(await pixel('prepared-provider-frame'), _coverColor);

    final refreshed = publication.copyWith(title: 'Новый заголовок');
    await tester.pumpWidget(app(refreshed));
    expect(tester.widget<Image>(find.byType(Image)).image, same(provider));
    expect(await pixel('metadata-refresh-frame'), _coverColor);

    final replacement =
        publication.copyWith(imageBytes: Uint8List.fromList(bytes));
    expect(replacement.imageProvider, isNull);
    await tester.pumpWidget(app(publication.copyWith(clearImageBytes: true)));
    expect(find.byType(Image), findsNothing);
    expect(await pixel('cleared-cover-frame'), isNot(_coverColor));
  });

  testWidgets('initial news strip occupies its final place without fake photos',
      (tester) async {
    const article = StudentHomeNews(
      id: 'first-network-publication',
      title: 'Новости кампуса',
      subtitle: '',
      body: '',
      icon: Icons.newspaper,
      gradientColors: [Colors.blue, Colors.blue],
    );
    Widget app({
      int visit = 0,
      bool pending = false,
      List<StudentHomeNews> news = const [],
    }) =>
        MaterialApp(
          home: StudentHomeView(
            contentLayoutVisit: visit,
            newsLoading: pending,
            data: StudentHomeData(
              profile:
                  const StudentHomeProfile(name: 'Студент', groupName: 'QA'),
              currentDate: DateTime(2026, 11, 27),
              lessons: const [],
              assignments: const [],
              news: news,
            ),
            hideHomePromo: true,
          ),
        );
    final heading = find.text('Сводка дня');
    await tester.pumpWidget(app(pending: true));
    final summaryY = tester.getTopLeft(heading).dy;
    expect(find.text('Загружаем новости…'), findsOneWidget);
    expect(find.byType(StudentHomeNewsCard), findsNothing);
    expect(find.byType(NewsImageFrame), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(heading).dy, summaryY);

    await tester.pumpWidget(app());
    expect(tester.getTopLeft(heading).dy, summaryY);
    expect(find.text('Загружаем новости…'), findsNothing);
    expect(find.text('Пока нет новостей для показа'), findsOneWidget);
    expect(find.byType(NewsImageFrame), findsNothing);
    await tester.pumpWidget(app(visit: 1));
    expect(find.byKey(const ValueKey('student-home-news')), findsNothing);
    expect(tester.getTopLeft(heading).dy, lessThan(summaryY));

    await tester.pumpWidget(app(visit: 2, pending: true));
    await tester.pumpWidget(app(visit: 2, news: [article]));
    expect(tester.getTopLeft(heading).dy, summaryY);
    expect(find.text('Загружаем новости…'), findsNothing);
    expect(find.text(article.title), findsOneWidget);
    await tester.pumpWidget(app(visit: 2));
    expect(find.byKey(const ValueKey('student-home-news')), findsNothing);
    expect(tester.getTopLeft(heading).dy, lessThan(summaryY));
  });
}
