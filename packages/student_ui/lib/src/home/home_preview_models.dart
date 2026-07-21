import 'dart:typed_data';

import 'package:flutter/material.dart';

class StudentHomeData {
  const StudentHomeData({
    required this.profile,
    required this.currentDate,
    required this.lessons,
    required this.assignments,
    required this.news,
    this.totalLessonsToday = 0,
    this.assignmentsCount = 0,
    this.lessonsFinishedForToday = false,
  });

  final StudentHomeProfile profile;
  final DateTime currentDate;
  final List<StudentHomeLesson> lessons;
  final List<StudentHomeAssignment> assignments;
  final List<StudentHomeNews> news;
  final int totalLessonsToday;
  final int assignmentsCount;
  final bool lessonsFinishedForToday;
}

class StudentHomeProfile {
  const StudentHomeProfile({
    required this.name,
    required this.groupName,
  });

  final String name;
  final String groupName;

  String get displayName => name.trim().isEmpty ? 'студент' : name.trim();
}

class StudentHomeLesson {
  const StudentHomeLesson({
    required this.subject,
    required this.start,
    required this.pairNumber,
    this.room = '',
    this.teacher = '',
  });

  final String subject;
  final TimeOfDay start;
  final int pairNumber;
  final String room;
  final String teacher;
}

class StudentHomeAssignment {
  const StudentHomeAssignment({
    required this.id,
    required this.title,
    required this.subject,
    required this.deadline,
    this.status = StudentHomeAssignmentStatus.notStarted,
    this.isDone = false,
  });

  final String id;
  final String title;
  final String subject;
  final String deadline;
  final StudentHomeAssignmentStatus status;
  final bool isDone;
}

enum StudentHomeAssignmentStatus {
  notStarted,
  inProgress,
  done,
}

class StudentHomeNews {
  const StudentHomeNews({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.icon,
    required this.gradientColors,
    this.variant = StudentHomeNewsVariant.gradientText,
    this.imageBytes,
    this.imageFocus = Alignment.center,
    this.overlayDarken = 0.42,
  });

  final String id;
  final String title;
  final String subtitle;
  final String body;
  final IconData icon;
  final List<Color> gradientColors;
  final StudentHomeNewsVariant variant;

  /// Optional local/remote decoded image bytes for card variants that use media.
  /// Kept as presentation data only — storage and upload live outside this package.
  final Uint8List? imageBytes;

  /// Focal point used with [BoxFit.cover] for news images.
  final Alignment imageFocus;

  /// Darken strength for [StudentHomeNewsVariant.imageOverlay] (0..1).
  final double overlayDarken;

  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;

  StudentHomeNews copyWith({
    String? id,
    String? title,
    String? subtitle,
    String? body,
    IconData? icon,
    List<Color>? gradientColors,
    StudentHomeNewsVariant? variant,
    Uint8List? imageBytes,
    bool clearImageBytes = false,
    Alignment? imageFocus,
    double? overlayDarken,
  }) {
    return StudentHomeNews(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      body: body ?? this.body,
      icon: icon ?? this.icon,
      gradientColors: gradientColors ?? this.gradientColors,
      variant: variant ?? this.variant,
      imageBytes: clearImageBytes ? null : (imageBytes ?? this.imageBytes),
      imageFocus: imageFocus ?? this.imageFocus,
      overlayDarken: overlayDarken ?? this.overlayDarken,
    );
  }
}

enum StudentHomeNewsVariant {
  gradientText,
  imageOverlay,
  imageOnly,
  imageWithText,
}
