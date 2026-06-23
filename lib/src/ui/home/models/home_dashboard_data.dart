import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';

class HomeDashboardData {
  final HomeUserProfile profile;
  final DateTime scheduleDate;
  final List<Lesson> todayLessons;
  final List<HomeAssignmentPreview> assignments;
  final List<HomeNewsItem> news;
  final Set<String> readNotificationIds;
  final int unreadMessagesCount;
  final String? warning;

  const HomeDashboardData({
    required this.profile,
    required this.scheduleDate,
    required this.todayLessons,
    required this.assignments,
    required this.news,
    this.readNotificationIds = const {},
    this.unreadMessagesCount = 0,
    this.warning,
  });

  int get lessonsCount => remainingLessons.length;
  int get assignmentsCount => assignments.length;
  int get totalLessonsToday => todayLessons.length;
  bool get hasLessonsToday => remainingLessons.isNotEmpty;
  bool get isScheduleForToday =>
      MskDate.isSameCalendarDate(scheduleDate, MskDate.today());
  bool get lessonsFinishedForToday =>
      isScheduleForToday && todayLessons.isNotEmpty && remainingLessons.isEmpty;

  List<Lesson> get remainingLessons {
    if (!isScheduleForToday) return [];

    final now = MskDate.now();
    final today = MskDate.today();
    final nowMinutes = MskDate.minutesOfDay(now);
    return todayLessons.where((lesson) {
      if (!MskDate.isSameCalendarDate(lesson.date, today)) return false;
      final endMinutes = lesson.end.hour * 60 + lesson.end.minute;
      return nowMinutes < endMinutes;
    }).toList();
  }

  Lesson? get nextLesson {
    final upcoming = remainingLessons;
    if (upcoming.isEmpty) return null;
    return upcoming.first;
  }
}

class HomeUserProfile {
  final String id;
  final String name;
  final String surname;
  final String groupName;
  final String avatarUrl;
  final String status;

  const HomeUserProfile({
    this.id = '',
    this.name = '',
    this.surname = '',
    this.groupName = '',
    this.avatarUrl = '',
    this.status = '',
  });

  String get displayName {
    final trimmedName = name.trim();
    if (trimmedName.isNotEmpty) return trimmedName;

    final trimmedSurname = surname.trim();
    if (trimmedSurname.isNotEmpty) return trimmedSurname;

    return 'студент';
  }

  factory HomeUserProfile.fromMap(Map<String, dynamic> map) {
    return HomeUserProfile(
      id: _readString(map, 'id'),
      name: _readString(map, 'name'),
      surname: _readString(map, 'surname'),
      groupName: _readString(map, 'group_name'),
      avatarUrl: _readString(map, 'avatar_url'),
      status: _readString(map, 'status'),
    );
  }

  static String _readString(Map<String, dynamic> map, String key) {
    return (map[key] ?? '').toString().trim();
  }
}

class HomeAssignmentPreview {
  final Assignment assignment;
  final String teamName;

  const HomeAssignmentPreview({
    required this.assignment,
    required this.teamName,
  });

  DateTime? get dueAt => assignment.dueAt;
  bool get isDone => assignment.completedByMe || assignment.status == 'done';
}

class HomeNewsItem {
  final String id;
  final String title;
  final String subtitle;
  final String body;
  final IconData icon;
  final List<Color> gradientColors;
  final HomeNewsType type;
  final DateTime createdAt;
  final int priority;

  const HomeNewsItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.icon,
    required this.gradientColors,
    required this.type,
    required this.createdAt,
    this.priority = 0,
  });
}

enum HomeNewsType {
  update,
  diary,
  materials,
  assignments,
}
