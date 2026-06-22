import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';

class HomeDashboardService {
  HomeDashboardService({
    SupabaseClient? client,
    ScheduleRepository? scheduleRepository,
    SupabaseLearningRepository? learningRepository,
  })  : _sb = client ?? Supabase.instance.client,
        _scheduleRepository = scheduleRepository ?? ScheduleRepository(),
        _learningRepository =
            learningRepository ?? SupabaseLearningRepository();

  final SupabaseClient _sb;
  final ScheduleRepository _scheduleRepository;
  final SupabaseLearningRepository _learningRepository;

  Future<HomeDashboardData> load() async {
    final profile = await _loadProfile();
    final results = await Future.wait<dynamic>([
      _loadTodayLessons(),
      _loadAssignments(profile.groupName),
    ]);

    final lessons = results[0] as List<Lesson>;
    final assignments = results[1] as List<HomeAssignmentPreview>;

    return HomeDashboardData(
      profile: profile,
      todayLessons: lessons,
      assignments: assignments.take(4).toList(),
      news: _localNews(),
      unreadMessagesCount: 0,
    );
  }

  Future<HomeUserProfile> _loadProfile() async {
    Map<String, dynamic>? cached;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user');
      if (raw != null && raw.isNotEmpty) {
        cached = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (e) {
      debugPrint('[home] local profile read failed: $e');
    }

    try {
      final rows = await _sb.rpc('get_my_profile') as List?;
      if (rows != null && rows.isNotEmpty) {
        final fresh = Map<String, dynamic>.from(rows.first as Map);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user', jsonEncode(fresh));
        return HomeUserProfile.fromMap(fresh);
      }
    } catch (e) {
      debugPrint('[home] get_my_profile failed: $e');
    }

    if (cached != null) return HomeUserProfile.fromMap(cached);

    return const HomeUserProfile();
  }

  Future<List<Lesson>> _loadTodayLessons() async {
    try {
      final today = _nowMsk();
      final monthLessons = await _scheduleRepository.loadMonth(today);
      return monthLessons
          .where((lesson) => _isSameDate(lesson.date, today))
          .toList()
        ..sort(_compareLessons);
    } catch (e) {
      debugPrint('[home] today lessons failed: $e');
      return [];
    }
  }

  Future<List<HomeAssignmentPreview>> _loadAssignments(String groupName) async {
    if (groupName.trim().isEmpty) return [];

    try {
      final teams = await _learningRepository.loadTeams(groupName);
      final previews = <HomeAssignmentPreview>[];

      for (final team in teams.take(8)) {
        previews.addAll(await _loadTeamAssignments(team));
      }

      previews.sort(_compareAssignments);
      return previews;
    } catch (e) {
      debugPrint('[home] assignments failed: $e');
      return [];
    }
  }

  Future<List<HomeAssignmentPreview>> _loadTeamAssignments(Team team) async {
    try {
      final assignments = await _learningRepository.loadAssignments(team.id);
      return assignments
          .where(
              (assignment) => assignment.published && !assignment.completedByMe)
          .map(
            (assignment) => HomeAssignmentPreview(
              assignment: assignment,
              teamName: team.name,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('[home] assignments for ${team.id} failed: $e');
      return [];
    }
  }

  int _compareLessons(Lesson a, Lesson b) {
    final pairCompare = a.pairNum.compareTo(b.pairNum);
    if (pairCompare != 0) return pairCompare;

    final aMinutes = a.start.hour * 60 + a.start.minute;
    final bMinutes = b.start.hour * 60 + b.start.minute;
    return aMinutes.compareTo(bMinutes);
  }

  int _compareAssignments(HomeAssignmentPreview a, HomeAssignmentPreview b) {
    final aDue = a.dueAt;
    final bDue = b.dueAt;
    if (aDue == null && bDue == null) {
      return b.assignment.createdAt.compareTo(a.assignment.createdAt);
    }
    if (aDue == null) return 1;
    if (bDue == null) return -1;
    return aDue.compareTo(bDue);
  }

  DateTime _nowMsk() => DateTime.now().toUtc().add(const Duration(hours: 3));

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  List<HomeNewsItem> _localNews() {
    final now = DateTime.now();
    return [
      HomeNewsItem(
        id: 'app_update',
        title: 'Главная стала полезнее',
        subtitle: 'Расписание, задания и подсказки теперь под рукой',
        body:
            'Главная стала полезнее: расписание, задания и важные подсказки теперь под рукой.',
        icon: Icons.auto_awesome_rounded,
        gradientColors: const [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
        type: HomeNewsType.update,
        createdAt: now,
        priority: 4,
      ),
      HomeNewsItem(
        id: 'personal_diary',
        title: 'Дневник',
        subtitle: 'Собирай заметки и материалы по предметам',
        body:
            'Появится место для заметок, подготовки к парам и личного прогресса.',
        icon: Icons.edit_note_rounded,
        gradientColors: const [Color(0xFFDCD0FA), Color(0xFFC5EFE5)],
        type: HomeNewsType.diary,
        createdAt: now.subtract(const Duration(days: 1)),
        priority: 3,
      ),
      HomeNewsItem(
        id: 'useful_materials',
        title: 'Материалы',
        subtitle: 'Полезные файлы появятся по семестрам',
        body:
            'Полезные ссылки, файлы и материалы по предметам будут доступны в разделе «Полезная».',
        icon: Icons.folder_copy_outlined,
        gradientColors: const [Color(0xFFC5EFE5), Color(0xFFAEE3D8)],
        type: HomeNewsType.materials,
        createdAt: now.subtract(const Duration(days: 2)),
        priority: 2,
      ),
      HomeNewsItem(
        id: 'chat_assignments',
        title: 'Задания',
        subtitle: 'Следи за дедлайнами своей группы',
        body:
            'Задания из команд будут собираться в одном месте, чтобы ничего не потерялось.',
        icon: Icons.assignment_turned_in_outlined,
        gradientColors: const [Color(0xFFFFE5B9), Color(0xFFDCD0FA)],
        type: HomeNewsType.assignments,
        createdAt: now.subtract(const Duration(days: 3)),
        priority: 1,
      ),
      HomeNewsItem(
        id: 'help_preview',
        title: 'Помощь',
        subtitle: 'Можно разобрать сложное задание',
        body:
            'Позже здесь появится аккуратный раздел помощи: можно будет разобраться с заданием, подготовиться к сдаче или понять, с чего начать.',
        icon: Icons.psychology_alt_outlined,
        gradientColors: const [Color(0xFFF0D4E6), Color(0xFFDCD0FA)],
        type: HomeNewsType.update,
        createdAt: now.subtract(const Duration(days: 4)),
        priority: 0,
      ),
    ];
  }
}
