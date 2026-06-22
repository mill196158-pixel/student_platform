import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';

class HomeDashboardData {
  final HomeUserProfile profile;
  final List<Lesson> todayLessons;
  final List<HomeAssignmentPreview> assignments;
  final List<HomeNewsItem> news;
  final int unreadMessagesCount;
  final String? warning;

  const HomeDashboardData({
    required this.profile,
    required this.todayLessons,
    required this.assignments,
    required this.news,
    this.unreadMessagesCount = 0,
    this.warning,
  });

  int get lessonsCount => todayLessons.length;
  int get assignmentsCount => assignments.length;
  bool get hasLessonsToday => todayLessons.isNotEmpty;

  Lesson? get nextLesson {
    if (todayLessons.isEmpty) return null;

    final now = TimeOfDay.now();
    final nowMinutes = now.hour * 60 + now.minute;
    for (final lesson in todayLessons) {
      final lessonMinutes = lesson.start.hour * 60 + lesson.start.minute;
      if (lessonMinutes >= nowMinutes) return lesson;
    }

    return todayLessons.last;
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
