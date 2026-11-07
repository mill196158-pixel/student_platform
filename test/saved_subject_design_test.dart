import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/info/subject_info_screen.dart';
import 'package:student_platform/src/ui/info/useful_subject.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final brightness in Brightness.values) {
    testWidgets('saved subject is readable and guarded in ${brightness.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final events = StreamController<AuthState>.broadcast(sync: true);
      final session = fakeSession('student');
      final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      final caps = SessionCapabilities(scope);
      expect(caps.grant(SessionCapabilityMode.cacheOnly,
          caps.beginAuthorization(scope.capture()!)!), isTrue);
      final permit = caps.capture(SessionCapability.cachedRead)!;
      const subject = UsefulSubject(id: 'course',
        title: 'Системы и сооружения водоснабжения и водоотведения',
        semesterNumber: 4, controlForm: 'Экзамен', description: 'Сохранённое описание',
        teacherName: 'Иван Иванов', teamName: '', teamIcon: '', teamGroupName: '');
      await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: brightness),
        home: SavedSubjectInfoScreen(subject: subject, capabilities: caps, permit: permit)));
      expect(find.text('Информация о предмете'), findsOneWidget);
      expect(find.text(subject.title), findsOneWidget);
      expect(find.text('4-й семестр · Экзамен'), findsOneWidget);
      expect(find.text('Сохранённая информация · без сети'), findsOneWidget);
      expect(find.text('Краткая информация'), findsOneWidget);
      expect(find.text('Сохранённое описание'), findsOneWidget);
      expect(find.text('Иван Иванов'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Полезные файлы'), 180,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Без сети нельзя проверить материалы'), findsOneWidget);
      expect(find.text('Материалы пока не загружены'), findsNothing);
      expect(find.text('Открыть чат'), findsNothing);
      expect(tester.takeException(), isNull);
      caps.block();
      await tester.pump();
      expect(find.text('Сохранённый предмет недоступен.'), findsOneWidget);
      expect(find.text(subject.title), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      caps.dispose(); scope.dispose(); await events.close();
    });
  }
}
