import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';

class HomeDashboardService {
  HomeDashboardService({
    SupabaseClient? client,
    ScheduleRepository? scheduleRepository,
    SupabaseLearningRepository? learningRepository,
    PublishedNewsCache? newsCache,
    NewsImageDiskCache? imageCache,
    http.Client? httpClient,
  })  : _sb = client ?? Supabase.instance.client,
        _scheduleRepository = scheduleRepository ?? ScheduleRepository(),
        _learningRepository =
            learningRepository ?? SupabaseLearningRepository(),
        _newsCache = newsCache ?? PublishedNewsCache(),
        _imageCache = imageCache ?? NewsImageDiskCache(),
        _http = httpClient ?? http.Client();

  final SupabaseClient _sb;
  final ScheduleRepository _scheduleRepository;
  final SupabaseLearningRepository _learningRepository;
  final PublishedNewsCache _newsCache;
  final NewsImageDiskCache _imageCache;
  final http.Client _http;

  /// Instant cache-first news (JSON + previously saved image bytes).
  /// Never hits the network.
  Future<List<HomeNewsItem>> loadCachedNews() async {
    final cached = await _newsCache.read();
    if (cached.isEmpty) return const [];
    return _hydrateImagesFromDisk(cached);
  }

  Future<HomeDashboardData> load() async {
    final scheduleDate = MskDate.today();
    final profile = await _loadProfile();
    final results = await Future.wait<dynamic>([
      _loadTodayLessons(scheduleDate),
      _loadAssignments(profile.groupName),
      _loadReadNotificationIds(),
      _loadPublishedNews(),
      _loadGroupActionDeadlines(),
    ]);

    final lessons = results[0] as List<Lesson>;
    final assignments = results[1] as List<HomeAssignmentPreview>;
    final readNotificationIds = results[2] as Set<String>;
    final news = results[3] as List<HomeNewsItem>;
    final groupActions = results[4] as List<HomeGroupActionPreview>;

    return HomeDashboardData(
      profile: profile,
      scheduleDate: scheduleDate,
      todayLessons: lessons,
      assignments: assignments.take(4).toList(),
      news: news,
      readNotificationIds: readNotificationIds,
      unreadMessagesCount: 0,
      groupActions: groupActions.take(4).toList(),
    );
  }

  /// Marks a published news post as seen (and optionally closed) for the user.
  Future<void> markNewsSeen(String newsId, {bool closed = false}) async {
    final id = newsId.trim();
    if (id.isEmpty) return;
    try {
      await _sb.rpc('mark_news_seen', params: {
        'p_news_id': id,
        'p_closed': closed,
      });
    } catch (e) {
      debugPrint('[home] mark_news_seen failed: $e');
    }
  }

  /// Cache-first / stale-while-revalidate load of the published news feed.
  ///
  /// - Disk/memory image bytes are attached immediately when available.
  /// - Fresh metadata comes from `get_my_published_news`.
  /// - On network failure the feed + last good images are kept.
  /// - Refresh never clears working image bytes for an unchanged cache key.
  Future<List<HomeNewsItem>> _loadPublishedNews() async {
    final cached = await _newsCache.read();
    final cachedWithImages = await _hydrateImagesFromDisk(cached);
    try {
      final response = await _sb.rpc('get_my_published_news');
      final rows = _asMapList(response);
      await _newsCache.write(rows);
      final fresh = rows.map(mapPublishedNews).toList();
      final merged =
          _mergeKeepingImages(previous: cachedWithImages, next: fresh);
      return _resolveNewsImages(merged, prefetchStory: true);
    } catch (e) {
      debugPrint('[home] published news failed: $e');
      if (cachedWithImages.isNotEmpty) {
        // Keep last good cache — do not wipe images on network error.
        return cachedWithImages;
      }
      return _localNews();
    }
  }

  List<HomeNewsItem> _mergeKeepingImages({
    required List<HomeNewsItem> previous,
    required List<HomeNewsItem> next,
  }) {
    final prevById = {for (final item in previous) item.id: item};
    final merged = <HomeNewsItem>[];
    for (final item in next) {
      final old = prevById[item.id];
      if (old?.imageBytes != null &&
          old!.imageCacheKey?.id != null &&
          old.imageCacheKey!.id == item.imageCacheKey?.id) {
        merged.add(item.copyWith(imageBytes: old.imageBytes));
      } else {
        merged.add(item);
      }
    }
    return merged;
  }

  Future<List<HomeNewsItem>> _hydrateImagesFromDisk(
    List<HomeNewsItem> items,
  ) async {
    final out = <HomeNewsItem>[];
    for (final item in items) {
      final key = item.imageCacheKey;
      if (key == null || item.imageBytes != null) {
        out.add(item);
        continue;
      }
      final bytes = await _imageCache.peek(key);
      out.add(bytes == null ? item : item.copyWith(imageBytes: bytes));
    }
    return out;
  }

  Future<List<HomeNewsItem>> _resolveNewsImages(
    List<HomeNewsItem> items, {
    bool prefetchStory = false,
  }) async {
    final priority = <int>{};
    for (var i = 0; i < items.length && i < 6; i++) {
      priority.add(i);
    }
    if (prefetchStory && items.isNotEmpty) {
      priority.add(0);
      if (items.length > 1) priority.add(1);
    }

    final resolved = List<HomeNewsItem>.from(items);
    final futures = <Future<void>>[];
    for (final index in priority) {
      futures.add(() async {
        final item = resolved[index];
        final key = item.imageCacheKey;
        if (key == null || item.imageBytes != null) return;
        final bytes = await _fetchNewsImage(key);
        if (bytes != null) {
          resolved[index] = item.copyWith(imageBytes: bytes);
          // Best-effort cleanup of older versions for the same path.
          unawaited(_imageCache.pruneOtherVersions(key.path, key.version));
        }
      }());
    }
    await Future.wait(futures);

    // Warm the rest in the background without blocking first paint.
    for (var i = 0; i < resolved.length; i++) {
      if (priority.contains(i)) continue;
      final item = resolved[i];
      final key = item.imageCacheKey;
      if (key == null || item.imageBytes != null) continue;
      unawaited(_fetchNewsImage(key));
    }
    return resolved;
  }

  /// Public helper for story sheet: resolve one item without clearing others.
  Future<Uint8List?> resolveNewsImageBytes(HomeNewsItem item) async {
    final key = item.imageCacheKey;
    if (key == null) return null;
    if (item.imageBytes != null && item.imageBytes!.isNotEmpty) {
      return item.imageBytes;
    }
    return _fetchNewsImage(key);
  }

  Future<Uint8List?> _fetchNewsImage(NewsImageCacheKey key) {
    return _imageCache.getOrFetch(key, () => _downloadNewsImage(key.path));
  }

  Future<Uint8List?> _downloadNewsImage(String path) async {
    try {
      final response = await _sb.functions.invoke(
        'news-media',
        body: {'action': 'createDownload', 'path': path},
      );
      if (response.status >= 400) {
        debugPrint(
          '[home] news image createDownload status=${response.status}',
        );
        return null;
      }
      final data = response.data;
      if (data is! Map) {
        debugPrint('[home] news image createDownload bad payload type');
        return null;
      }
      final signedUrl = (data['signedUrl'] ?? '').toString();
      // Never persist or log the signed URL — use it only for this GET.
      if (signedUrl.isEmpty) {
        debugPrint('[home] news image createDownload empty url');
        return null;
      }
      final download = await _http.get(Uri.parse(signedUrl));
      if (download.statusCode != 200) {
        debugPrint(
          '[home] news image bytes status=${download.statusCode}',
        );
        return null;
      }
      final bytes = download.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      // Never log JWT / signed URLs / tokens — type only.
      debugPrint('[home] news image download failed type=${e.runtimeType}');
      return null;
    }
  }

  static List<Map<String, dynamic>> _asMapList(dynamic data) {
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (data is String && data.isNotEmpty) {
      try {
        return _asMapList(jsonDecode(data));
      } catch (_) {
        return const [];
      }
    }
    return const [];
  }

  Future<void> setAssignmentDone({
    required String assignmentId,
    required bool done,
  }) async {
    await _sb.rpc('set_assignment_done', params: {
      'p_assignment_id': assignmentId,
      'p_done': done,
    });
  }

  Future<void> markNotificationRead(String notificationId) async {
    final userId = _sb.auth.currentUser?.id;
    final trimmedId = notificationId.trim();
    if (userId == null || trimmedId.isEmpty) return;

    try {
      await _sb.from('home_notification_reads').upsert(
        {
          'user_id': userId,
          'notification_id': trimmedId,
          'read_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,notification_id',
      );
    } catch (e) {
      debugPrint('[home] mark notification read failed: $e');
    }
  }

  Future<List<HomeGroupActionPreview>> _loadGroupActionDeadlines() async {
    try {
      final repo = ChatGroupActionsRepository(client: _sb);
      final items = await repo.listMyGroupActionDeadlines();
      return items
          .map(
            (GroupActionDeadline e) => HomeGroupActionPreview(
              eventType: e.eventType,
              entityId: e.entityId,
              title: e.title,
              occursAt: e.occursAt,
              chatId: e.chatId,
              cardMessageId: e.cardMessageId,
              teamId: e.teamId,
              teamName: e.teamName,
              status: e.status,
              myPickText: e.myPickText,
              canDelete: e.canDelete,
            ),
          )
          .toList()
        ..sort((a, b) => a.occursAt.compareTo(b.occursAt));
    } catch (e) {
      debugPrint('[home] group action deadlines failed: $e');
      return const [];
    }
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

  Future<Set<String>> _loadReadNotificationIds() async {
    final userId = _sb.auth.currentUser?.id;
    if (userId == null) return {};

    try {
      final rows = await _sb
          .from('home_notification_reads')
          .select('notification_id')
          .eq('user_id', userId);
      return rows
          .map((row) => (row['notification_id'] ?? '').toString().trim())
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (e) {
      debugPrint('[home] notification reads load failed: $e');
      return {};
    }
  }

  Future<List<Lesson>> _loadTodayLessons(DateTime today) async {
    try {
      final todayLessons = await _scheduleRepository.loadRange(today, days: 1);
      return todayLessons
          .where((lesson) => MskDate.isSameCalendarDate(lesson.date, today))
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
          .where((assignment) =>
              assignment.published &&
              !assignment.completedByMe &&
              assignment.subjectOfferingId?.trim().isNotEmpty == true)
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
            'Полезные ссылки, файлы и материалы по предметам будут доступны в разделе «База».',
        icon: Icons.menu_book_outlined,
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

/// Persists the published news feed for cache-first / stale-while-revalidate.
///
/// Only the JSON returned by `get_my_published_news` is stored (never image
/// bytes). Cache is never cleared on network error.
class PublishedNewsCache {
  PublishedNewsCache({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static const String key = 'home_published_news_v1';

  Future<List<HomeNewsItem>> read() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => mapPublishedNews(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (e) {
      debugPrint('[home] news cache read failed: $e');
    }
    return const [];
  }

  Future<void> write(List<Map<String, dynamic>> rows) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(key, jsonEncode(rows));
    } catch (e) {
      debugPrint('[home] news cache write failed: $e');
    }
  }
}

/// Maps a `get_my_published_news` row into a [HomeNewsItem].
HomeNewsItem mapPublishedNews(Map<String, dynamic> json) {
  final variant = _newsVariantFromString(json['variant']?.toString());
  final id = (json['id'] ?? '').toString();
  return HomeNewsItem(
    id: id,
    title: (json['title'] ?? '').toString(),
    subtitle: (json['subtitle'] ?? '').toString(),
    body: (json['body'] ?? '').toString(),
    icon: _iconForVariant(variant, id),
    gradientColors: _newsColorsFromHex(json['gradient_colors']),
    type: HomeNewsType.update,
    createdAt: _parseDate(json['created_at']) ?? DateTime.now(),
    priority: _parseInt(json['priority']),
    variant: variant,
    imageFocus: Alignment(
      _parseDouble(json['image_focus_x']),
      _parseDouble(json['image_focus_y']),
    ),
    overlayDarken: _parseDouble(json['overlay_opacity'], fallback: 0.42),
    imagePath: _nullableString(json['image_path']),
    publishedAt: _parseDate(json['published_at']),
    updatedAt: _parseDate(json['updated_at']),
  );
}

StudentHomeNewsVariant _newsVariantFromString(String? value) {
  switch (value) {
    case 'imageOverlay':
      return StudentHomeNewsVariant.imageOverlay;
    case 'imageOnly':
      return StudentHomeNewsVariant.imageOnly;
    case 'imageWithText':
      return StudentHomeNewsVariant.imageWithText;
    case 'gradientText':
    default:
      return StudentHomeNewsVariant.gradientText;
  }
}

IconData _iconForVariant(StudentHomeNewsVariant variant, String seed) {
  // Image variants must not show a decorative folder glyph on the card/story.
  if (variant != StudentHomeNewsVariant.gradientText) {
    return Icons.auto_awesome_rounded;
  }
  const icons = [
    Icons.auto_awesome_rounded,
    Icons.edit_note_rounded,
    Icons.campaign_outlined,
    Icons.assignment_turned_in_outlined,
  ];
  return icons[seed.hashCode.abs() % icons.length];
}

List<Color> _newsColorsFromHex(dynamic raw) {
  const fallback = [Color(0xFF7367F0), Color(0xFFB784F7)];
  if (raw is List) {
    final colors = <Color>[];
    for (final item in raw) {
      if (item == null) continue;
      final parsed = _colorFromHex(item.toString());
      if (parsed != null) colors.add(parsed);
    }
    if (colors.length >= 2) return colors;
    if (colors.length == 1) return [colors.first, colors.first];
  }
  return fallback;
}

Color? _colorFromHex(String value) {
  var hex = value.replaceAll('#', '').trim();
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length == 6) hex = 'FF$hex';
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(parsed);
}

int _parseInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _parseDouble(dynamic value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

String? _nullableString(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
