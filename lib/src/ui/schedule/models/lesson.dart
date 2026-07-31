import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';

enum LessonType { lecture, practice, lab, other }

class Lesson {
  final String id;
  final DateTime date;
  final int week;
  final String day; // "ПН", ...
  final int pairNum;
  final TimeOfDay start;
  final TimeOfDay end;
  final String subjectRaw; // как в БД
  final String? room;
  final String? teacher;
  final String? groupId;
  final String? subjectId;
  final String? subjectOfferingId;
  final String? academicYearId;
  final String? academicTermId;
  final int? semesterNumber;
  final String? aliasMatchStatus;

  Lesson({
    required this.id,
    required this.date,
    required this.week,
    required this.day,
    required this.pairNum,
    required this.start,
    required this.end,
    required this.subjectRaw,
    this.room,
    this.teacher,
    this.groupId,
    this.subjectId,
    this.subjectOfferingId,
    this.academicYearId,
    this.academicTermId,
    this.semesterNumber,
    this.aliasMatchStatus,
  });

  factory Lesson.fromMap(Map<String, dynamic> m) {
    TimeOfDay parseTimeOfDay(dynamic value) {
      final String raw = value?.toString() ?? '00:00:00';
      final parts = raw.split(':');
      final hours = int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0;
      final minutes = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
      return TimeOfDay(hour: hours, minute: minutes);
    }

    DateTime parseDate(dynamic value) {
      return MskDate.parseDatabaseDate(value);
    }

    int parseInt(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    int? parseOptionalInt(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toInt();
      return int.tryParse(value.toString());
    }

    String? parseOptionalString(dynamic value) {
      final text = (value ?? '').toString().trim();
      return text.isEmpty ? null : text;
    }

    final dynamic idValue = m['id'];
    final String id = idValue is String ? idValue : (idValue?.toString() ?? '');

    return Lesson(
      id: id,
      date: parseDate(m['date']),
      week: parseInt(m['week']),
      day: (m['day'] ?? '').toString(),
      pairNum: parseInt(m['pair_num']),
      start: parseTimeOfDay(m['time_start']),
      end: parseTimeOfDay(m['time_end']),
      subjectRaw: (m['subject'] ?? '').toString(),
      room: (m['room'] as String?),
      teacher: (m['teacher'] as String?),
      groupId: parseOptionalString(m['group_id']),
      subjectId: parseOptionalString(m['subject_id']),
      subjectOfferingId: parseOptionalString(m['subject_offering_id']),
      academicYearId: parseOptionalString(m['academic_year_id']),
      academicTermId: parseOptionalString(m['academic_term_id']),
      semesterNumber: parseOptionalInt(m['semester_number']),
      aliasMatchStatus: parseOptionalString(m['alias_match_status']),
    );
  }

  Lesson copyWithAcademicFields(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return this;

    String? optionalString(dynamic value, String? fallback) {
      final text = (value ?? '').toString().trim();
      return text.isEmpty ? fallback : text;
    }

    int? optionalInt(dynamic value, int? fallback) {
      if (value == null) return fallback;
      if (value is num) return value.toInt();
      return int.tryParse(value.toString()) ?? fallback;
    }

    return Lesson(
      id: id,
      date: date,
      week: week,
      day: day,
      pairNum: pairNum,
      start: start,
      end: end,
      subjectRaw: subjectRaw,
      room: room,
      teacher: teacher,
      groupId: optionalString(m['group_id'], groupId),
      subjectId: optionalString(m['subject_id'], subjectId),
      subjectOfferingId:
          optionalString(m['subject_offering_id'], subjectOfferingId),
      academicYearId: optionalString(m['academic_year_id'], academicYearId),
      academicTermId: optionalString(m['academic_term_id'], academicTermId),
      semesterNumber: optionalInt(m['semester_number'], semesterNumber),
      aliasMatchStatus:
          optionalString(m['alias_match_status'], aliasMatchStatus),
    );
  }

  /// Очищенное название без суффикса типа занятия.
  String get subject =>
      subjectRaw.replaceAll(RegExp(r'\((л|пр|лаб|сем)\.\)\s*$'), '').trim();

  /// Тип по суффиксу/ключевым словам из импортированного расписания.
  LessonType get type {
    final s = subjectRaw.toLowerCase();
    if (s.contains('(лаб.)') || s.contains('лаборатор')) {
      return LessonType.lab;
    }
    if (s.contains('(пр.)') ||
        s.contains('(сем.)') ||
        s.contains('практика') ||
        s.contains('семинар')) {
      return LessonType.practice;
    }
    if (s.contains('(л.)') || s.contains('лекция')) {
      return LessonType.lecture;
    }
    return LessonType.other;
  }

  bool get isRemote => (room ?? '').toLowerCase().contains('дист');

  bool get hasSubjectLink => (subjectOfferingId ?? '').isNotEmpty;
}
