import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/team/team_roster_pdf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('roster PDF builds non-empty bytes with Cyrillic names', () async {
    final bytes = await const TeamRosterPdfService().buildBytes(
      teamTitle: 'Математический анализ',
      groupLabel: 'ВВ-2024',
      rows: const [
        TeamRosterPdfRow(index: 1, displayName: 'Баландина Дарья'),
        TeamRosterPdfRow(index: 2, displayName: 'Иванова Анастасия'),
        TeamRosterPdfRow(index: 3, displayName: 'Исаченко Александр'),
      ],
    );
    expect(bytes.length, greaterThan(500));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('25 typical names fit on one landscape A4 page', () async {
    final rows = [
      for (var i = 1; i <= 25; i++)
        TeamRosterPdfRow(index: i, displayName: 'Студент Тестовый $i'),
    ];
    final bytes = await const TeamRosterPdfService().buildBytes(
      teamTitle: 'Математический анализ',
      groupLabel: '1-См(ВВ)-2',
      rows: rows,
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(countRosterPdfPages(bytes), 1);
  });

  test('long roster still produces a valid multi-page PDF', () async {
    final rows = [
      for (var i = 1; i <= 45; i++)
        TeamRosterPdfRow(index: i, displayName: 'Студент Тестовый $i'),
    ];
    final bytes = await const TeamRosterPdfService().buildBytes(
      teamTitle: 'Команда',
      groupLabel: null,
      rows: rows,
    );
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(countRosterPdfPages(bytes), greaterThanOrEqualTo(2));
  });

  test('attendance grid has fixed column count for landscape roster', () {
    expect(TeamRosterPdfService.attendanceColumns, 12);
  });
}
