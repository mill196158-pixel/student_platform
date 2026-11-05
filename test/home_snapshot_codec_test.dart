import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';

void main() {
  test('lesson retains date, time, original subject and academic links', () {
    final lesson = Lesson(
        id: 'lesson',
        date: DateTime(2026, 11, 5),
        week: 2,
        day: 'ЧТ',
        pairNum: 3,
        start: const TimeOfDay(hour: 9, minute: 5),
        end: const TimeOfDay(hour: 10, minute: 40),
        subjectRaw: 'Вода (лаб.)',
        room: '42',
        teacher: 'Преподаватель',
        groupId: 'group',
        subjectId: 'subject',
        subjectOfferingId: 'offering',
        academicYearId: 'year',
        academicTermId: 'term',
        semesterNumber: 4,
        aliasMatchStatus: 'matched');
    final map = HomeSnapshotCodec.lessonToMap(lesson);
    final result = HomeSnapshotCodec.lessonFromMap(map)!;
    expect(HomeSnapshotCodec.lessonToMap(result), map);
    expect(result.type, LessonType.lab);
    expect(map['date'], '2026-11-05');
  });

  test('damaged lesson cannot acquire a fabricated date or time', () {
    final good = HomeSnapshotCodec.lessonToMap(Lesson(
        id: 'a',
        date: DateTime(2026),
        week: 1,
        day: 'ЧТ',
        pairNum: 1,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 0),
        subjectRaw: 'Предмет'));
    for (final bad in [
      {...good}..remove('date'),
      {...good, 'date': '2026-02-30'},
      {...good}..remove('time_start'),
      {...good, 'time_end': '25:00'},
    ]) {
      expect(HomeSnapshotCodec.lessonFromMap(bad), isNull);
    }
  });

  test('assignment retains its fields and rejects missing creation date', () {
    final assignment = Assignment(
        id: 'a',
        title: 'Задание',
        description: 'Детали',
        published: true,
        votes: 2,
        completedByMe: false,
        createdBy: 'student',
        createdAt: DateTime.utc(2026, 1, 1),
        dueAt: DateTime.utc(2026, 2, 1),
        attachments: const [
          {'name': 'file', 'path': 'path'}
        ],
        status: 'open',
        subjectOfferingId: 'offering',
        groupId: 'group',
        subjectId: 'subject',
        academicYearId: 'year',
        academicTermId: 'term',
        semesterNumber: 3);
    final map = HomeSnapshotCodec.assignmentToMap(
        HomeAssignmentPreview(assignment: assignment, teamName: 'Команда'));
    final result = HomeSnapshotCodec.assignmentFromMap(map)!;
    expect(HomeSnapshotCodec.assignmentToMap(result), map);
    final corrupted = Map<String, dynamic>.from(map);
    corrupted['assignment'] =
        Map<String, dynamic>.from(map['assignment'] as Map)
          ..remove('createdAt');
    expect(HomeSnapshotCodec.assignmentFromMap(corrupted), isNull);
    final original = Map<String, dynamic>.from(map['assignment'] as Map);
    for (final bad in [
      {...original}..remove('completedByMe'),
      {...original, 'published': 'yes'},
      {...original, 'dueAt': 'broken'},
      {...original, 'createdAt': '2026-02-30T12:00:00Z'},
      {...original, 'dueAt': '2026-11-05T25:61:00Z'},
      {
        ...original,
        'attachments': [
          {'name': 12}
        ]
      },
    ]) {
      expect(HomeSnapshotCodec.assignmentFromMap({...map, 'assignment': bad}),
          isNull);
    }
  });
}
