import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';

/// Strict codecs for persisted data; malformed cached values are never
/// converted into today's lesson or a task with an invented creation date.
class HomeSnapshotCodec {
  static Map<String, dynamic> lessonToMap(Lesson lesson) => {
        'id': lesson.id,
        'date': MskDate.isoDate(lesson.date),
        'week': lesson.week,
        'day': lesson.day,
        'pair_num': lesson.pairNum,
        'time_start': _time(lesson.start.hour, lesson.start.minute),
        'time_end': _time(lesson.end.hour, lesson.end.minute),
        'subject': lesson.subjectRaw,
        'room': lesson.room,
        'teacher': lesson.teacher,
        'group_id': lesson.groupId,
        'subject_id': lesson.subjectId,
        'subject_offering_id': lesson.subjectOfferingId,
        'academic_year_id': lesson.academicYearId,
        'academic_term_id': lesson.academicTermId,
        'semester_number': lesson.semesterNumber,
        'alias_match_status': lesson.aliasMatchStatus,
      };

  static Lesson? lessonFromMap(Map<String, dynamic> value) {
    final date = value['date'];
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        date is! String ||
        !_validDate(date) ||
        !_validTime(value['time_start']) ||
        !_validTime(value['time_end']) ||
        value['week'] is! int ||
        value['pair_num'] is! int ||
        value['day'] is! String ||
        value['subject'] is! String) return null;
    try {
      return Lesson.fromMap(value);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> assignmentToMap(HomeAssignmentPreview item) => {
        'teamName': item.teamName,
        'assignment': item.assignment.toJson(),
      };

  static HomeAssignmentPreview? assignmentFromMap(Map<String, dynamic> value) {
    final item = value['assignment'];
    if (value['teamName'] is! String ||
        item is! Map ||
        item['id'] is! String ||
        (item['id'] as String).isEmpty ||
        item['title'] is! String ||
        item['description'] is! String ||
        item['createdBy'] is! String ||
        item['published'] is! bool ||
        item['completedByMe'] is! bool ||
        item['votes'] is! int ||
        item['createdAt'] is! String ||
        !_validDateTime(item['createdAt'] as String)) return null;
    for (final key in [
      'link',
      'due',
      'status',
      'subjectOfferingId',
      'groupId',
      'subjectId',
      'academicYearId',
      'academicTermId',
    ]) {
      if (!item.containsKey(key) || (item[key] != null && item[key] is! String))
        return null;
    }
    for (final key in ['dueAt', 'publishedAt']) {
      if (!item.containsKey(key) ||
          (item[key] != null &&
              (item[key] is! String || !_validDateTime(item[key] as String))))
        return null;
    }
    if (!item.containsKey('semesterNumber') ||
        (item['semesterNumber'] != null && item['semesterNumber'] is! int) ||
        item['attachments'] is! List) return null;
    for (final attachment in item['attachments'] as List) {
      if (attachment is! Map ||
          attachment.entries
              .any((entry) => entry.key is! String || entry.value is! String))
        return null;
    }
    try {
      return HomeAssignmentPreview(
        assignment: Assignment.fromJson(Map<String, dynamic>.from(item)),
        teamName: value['teamName'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _validDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final parsed = DateTime.tryParse(value);
    return parsed != null && MskDate.isoDate(parsed) == value;
  }

  static bool _validDateTime(String value) {
    final match =
        RegExp(r'^\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z)?$')
            .firstMatch(value);
    if (match == null || !_validDate(value.substring(0, 10))) return false;
    return int.parse(match[1]!) < 24 &&
        int.parse(match[2]!) < 60 &&
        int.parse(match[3]!) < 60 &&
        DateTime.tryParse(value) != null;
  }

  static bool _validTime(Object? value) {
    if (value is! String || !RegExp(r'^\d{2}:\d{2}$').hasMatch(value))
      return false;
    final parts = value.split(':');
    return int.parse(parts[0]) < 24 && int.parse(parts[1]) < 60;
  }

  static String _time(int hour, int minute) =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
