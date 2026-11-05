import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
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
    AuthSessionScope? sessionScope,
    HomeSnapshotCache? snapshotCache,
  })  : _sb = client ?? Supabase.instance.client,
        _sessionScope = sessionScope,
        _snapshotCache = snapshotCache ??
            (sessionScope == null
                ? null
                : HomeSnapshotCache(
                    currentUserId: () => sessionScope.capture()?.userId,
                    sessionGeneration: () => sessionScope.generation,
                    sessionIdentity: sessionScope.capture,
                  )),
        _scheduleRepository = scheduleRepository ?? ScheduleRepository(),
        _learningRepository =
            learningRepository ?? SupabaseLearningRepository(),
        _newsCache = newsCache ??
            PublishedNewsCache(
              currentUserId: () =>
                  (client ?? Supabase.instance.client).auth.currentUser?.id,
            ),
        _imageCache = imageCache ?? NewsImageDiskCache(),
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  String? get currentUserId => _sb.auth.currentUser?.id;

  final SupabaseClient _sb;
  final ScheduleRepository _scheduleRepository;
  final SupabaseLearningRepository _learningRepository;
  final PublishedNewsCache _newsCache;
  final NewsImageDiskCache _imageCache;
  final http.Client _http;
  final bool _ownsHttpClient;
  final AuthSessionScope? _sessionScope;
  final HomeSnapshotCache? _snapshotCache;
  bool _disposed = false;
  int _loadRevision = 0;

  void dispose() {
    _disposed = true;
    _loadRevision++;
    if (_ownsHttpClient) _http.close();
  }

  /// Instant cache-first news (JSON + previously saved image bytes).
  /// Never hits the network.
  Future<List<HomeNewsItem>> loadCachedNews() async {
    final cached = await _newsCache.read();
    if (cached.isEmpty) return const [];
    return _hydrateImagesFromDisk(cached);
  }

  Future<HomeDashboardData> load({
    void Function(HomeDashboardData)? onUpdate,
    HomeDashboardData? previous,
  }) async {
    final revision = ++_loadRevision;
    final source = _sessionScope;
    if (source != null) await source.ready;
    final authScope = source?.capture();
    final userId = _sb.auth.currentUser?.id;
    bool current() =>
        !_disposed &&
        revision == _loadRevision &&
        _sb.auth.currentUser?.id == userId &&
        (source == null || (authScope != null && source.isCurrent(authScope)));
    if (!current()) throw HomeLoadCancelled();
    final cache = _snapshotCache;
    final cacheScope = userId == null ? null : cache?.captureScope(userId);
    final scheduleDate = MskDate.today();
    final validPrevious =
        previous?.profile.id == userId && userId != null ? previous : null;
    var profile = validPrevious?.profile ?? const HomeUserProfile();
    var lessons = validPrevious?.isScheduleForToday == true
        ? validPrevious!.todayLessons
        : <Lesson>[];
    var assignments = validPrevious?.assignments ?? <HomeAssignmentPreview>[];
    var reads = validPrevious?.readNotificationIds ?? <String>{};
    var news = validPrevious?.news ?? <HomeNewsItem>[];
    var actions = validPrevious?.groupActions ?? <HomeGroupActionPreview>[];
    String? scheduleStatus = 'Загружаем расписание…';
    String? assignmentsStatus = 'Загружаем ближайшие дела…';
    var scheduleFromCache = false;
    var assignmentsFromCache = false;
    var profileFromCache = false;
    if (validPrevious == null &&
        cache != null &&
        cacheScope != null &&
        userId != null) {
      Future<HomeSectionSnapshot?> safeRead(HomeSnapshotSection section) async {
        try {
          return await cache.read(userId, section);
        } catch (_) {
          return null;
        }
      }

      final cached = await Future.wait([
        safeRead(HomeSnapshotSection.schedule),
        safeRead(HomeSnapshotSection.assignments),
        safeRead(HomeSnapshotSection.profile),
      ]).timeout(const Duration(seconds: 1),
          onTimeout: () => [null, null, null]);
      if (!current() || !cache.isCurrent(cacheScope)) throw HomeLoadCancelled();
      final schedule = cached[0];
      if (schedule != null && schedule.date == MskDate.isoDate(scheduleDate)) {
        final decoded =
            schedule.items.map(HomeSnapshotCodec.lessonFromMap).toList();
        if (decoded.every((item) => item != null)) {
          lessons = decoded.cast<Lesson>();
          scheduleStatus = 'Сохранённое расписание';
          scheduleFromCache = true;
        }
      }
      final savedAssignments = cached[1];
      if (savedAssignments != null) {
        final decoded = savedAssignments.items
            .map(HomeSnapshotCodec.assignmentFromMap)
            .toList();
        if (decoded.every((item) => item != null)) {
          assignments = decoded.cast<HomeAssignmentPreview>();
          assignmentsStatus = 'Сохранённые задания';
          assignmentsFromCache = true;
        }
      }
      final savedProfile = cached[2];
      if (savedProfile != null &&
          savedProfile.items.length == 1 &&
          savedProfile.items.first['id'] == userId) {
        profile = HomeUserProfile.fromMap(savedProfile.items.first);
        profileFromCache = true;
      }
    }
    var assignmentsReady = false;
    var actionsReady = false;
    void updateAssignmentStatus() {
      if (assignmentsReady && actionsReady) assignmentsStatus = null;
    }

    HomeDashboardData snapshot() => HomeDashboardData(
        scheduleStatus: scheduleStatus,
        assignmentsStatus: assignmentsStatus,
        profile: profile,
        scheduleDate: scheduleDate,
        todayLessons: lessons,
        assignments: assignments.take(4).toList(),
        news: news,
        readNotificationIds: reads,
        groupActions: actions.take(4).toList());
    void publish() {
      if (current()) onUpdate?.call(snapshot());
    }

    // Paint the available cache without waiting for unrelated network calls.
    // The later profile/news callbacks will fill their existing sections.
    if (scheduleFromCache || assignmentsFromCache || profileFromCache)
      publish();

    // Independent work starts before the remote profile. Media never gates
    // schedule or assignments; each completed section is painted immediately.
    final profileWork = _loadProfile(
        isCurrent: current,
        fallback: profile.id == userId ? profile : null,
        onFresh: (fresh) {
          if (cache != null &&
              cacheScope != null &&
              current() &&
              cache.isCurrent(cacheScope)) {
            unawaited(cache
                .write(
                    scope: cacheScope,
                    section: HomeSnapshotSection.profile,
                    items: [fresh],
                    savedAt: DateTime.now())
                .catchError((Object _) => false));
          }
        },
        onCached: (cached) {
          profile = cached;
          publish();
        }).then((value) {
      profile = value;
      publish();
    });
    final assignmentsWork = _loadAssignments(isCurrent: current)
        .timeout(const Duration(seconds: 15))
        .then((value) {
      if (!current()) return;
      assignments = value;
      assignmentsFromCache = false;
      assignmentsReady = true;
      updateAssignmentStatus();
      publish();
      if (cache != null && cacheScope != null && cache.isCurrent(cacheScope)) {
        unawaited(cache
            .write(
                scope: cacheScope,
                section: HomeSnapshotSection.assignments,
                items: value
                    .take(4)
                    .map(HomeSnapshotCodec.assignmentToMap)
                    .toList(),
                savedAt: DateTime.now())
            .catchError((Object _) => false));
      }
    }, onError: (Object error) {
      assignmentsStatus = assignmentsFromCache
          ? 'Сохранённые задания'
          : 'Не удалось обновить задания';
      publish();
    });
    await Future.wait<void>([
      profileWork,
      assignmentsWork,
      _loadTodayLessons(scheduleDate).timeout(const Duration(seconds: 15)).then(
          (value) {
        if (!current()) return;
        lessons = value;
        scheduleFromCache = false;
        scheduleStatus = null;
        publish();
        if (cache != null &&
            cacheScope != null &&
            cache.isCurrent(cacheScope)) {
          unawaited(cache
              .write(
                  scope: cacheScope,
                  section: HomeSnapshotSection.schedule,
                  date: MskDate.isoDate(scheduleDate),
                  items: value.map(HomeSnapshotCodec.lessonToMap).toList(),
                  savedAt: DateTime.now())
              .catchError((Object _) => false));
        }
      }, onError: (Object error) {
        scheduleStatus = scheduleFromCache
            ? 'Сохранённое расписание'
            : 'Не удалось обновить расписание';
        publish();
      }),
      _loadReadNotificationIds().then((value) {
        reads = value;
        publish();
      }),
      _loadPublishedNews(
          isCurrent: current,
          onMetadata: (value) {
            news = value;
            publish();
          }).then((value) {
        news = value;
        publish();
      }),
      _loadGroupActionDeadlines().timeout(const Duration(seconds: 15)).then(
          (value) {
        actions = value;
        actionsReady = true;
        updateAssignmentStatus();
        publish();
      }, onError: (Object error) {
        assignmentsStatus = assignmentsFromCache
            ? 'Сохранённые задания'
            : 'Не удалось обновить ближайшие дела';
        publish();
      }),
    ]);
    if (!current()) throw HomeLoadCancelled();
    return snapshot();
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
  Future<List<HomeNewsItem>> _loadPublishedNews({
    void Function(List<HomeNewsItem>)? onMetadata,
    bool Function()? isCurrent,
  }) async {
    final newsUser = _sb.auth.currentUser?.id;
    bool current() =>
        _sb.auth.currentUser?.id == newsUser && (isCurrent?.call() ?? true);
    final cached = await _newsCache.read(owner: newsUser, isCurrent: current);
    if (!current()) return const [];
    final cachedWithImages = await _hydrateImagesFromDisk(cached);
    if (!current()) return const [];
    if (cachedWithImages.isNotEmpty) onMetadata?.call(cachedWithImages);
    try {
      final response = await _sb
          .rpc('get_my_published_news')
          .timeout(const Duration(seconds: 12));
      final rows = _asMapList(response);
      if (!current()) return const [];
      await _newsCache.write(rows, owner: newsUser, isCurrent: current);
      if (!current()) return const [];
      final fresh = rows.map(mapPublishedNews).toList();
      final merged =
          _mergeKeepingImages(previous: cachedWithImages, next: fresh);
      onMetadata?.call(merged);
      // Media owns its own deadlines; the dashboard timeout must not discard
      // a successful cover arriving after other sections have finished.
      unawaited(_resolveNewsImages(merged, onImage: (items) {
        if (current()) onMetadata?.call(items);
      }));
      return merged;
    } catch (e) {
      debugPrint('[home] published news failed: $e');
      if (cachedWithImages.isNotEmpty) {
        // Keep last good cache — do not wipe images on network error.
        return cachedWithImages;
      }
      return _sessionScope == null ? _localNews() : const [];
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
    void Function(List<HomeNewsItem>)? onImage,
  }) async {
    final resolved = List<HomeNewsItem>.from(items);
    var next = 0;
    Future<void> worker() async {
      while (next < resolved.length) {
        final index = next++;
        final item = resolved[index];
        final key = item.imageCacheKey;
        if (key == null || item.imageBytes != null) continue;
        try {
          final bytes = await _fetchNewsImage(key);
          if (bytes == null || bytes.isEmpty) continue;
          resolved[index] = item.copyWith(imageBytes: bytes);
          onImage?.call(List<HomeNewsItem>.unmodifiable(resolved));
          // Versioned entries expire through the bounded cache eviction.
          // A late old refresh must never prune a newer cover version.
        } catch (error) {
          debugPrint('[home] news cover failed type=${error.runtimeType}');
        }
      }
    }

    await Future.wait(List.generate(items.length.clamp(0, 6), (_) => worker()));
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
      ).timeout(const Duration(seconds: 10));
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
      final download = await _http
          .get(Uri.parse(signedUrl))
          .timeout(const Duration(seconds: 45));
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
      rethrow;
    }
  }

  Future<HomeUserProfile> _loadProfile({
    void Function(HomeUserProfile)? onCached,
    void Function(Map<String, dynamic>)? onFresh,
    bool Function()? isCurrent,
    HomeUserProfile? fallback,
  }) async {
    final userId = _sb.auth.currentUser?.id;
    Map<String, dynamic>? cached;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user');
      if (raw != null && raw.isNotEmpty) {
        final candidate = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        if (userId != null &&
            candidate['id'] == userId &&
            _sb.auth.currentUser?.id == userId) {
          cached = candidate;
          if (fallback == null)
            onCached?.call(HomeUserProfile.fromMap(candidate));
        }
      }
    } catch (e) {
      debugPrint('[home] local profile read failed: $e');
    }

    try {
      final rows = await _sb
          .rpc('get_my_profile')
          .timeout(const Duration(seconds: 12)) as List?;
      if (rows != null && rows.isNotEmpty) {
        final fresh = Map<String, dynamic>.from(rows.first as Map);
        final prefs = await SharedPreferences.getInstance();
        if (_sb.auth.currentUser?.id != userId ||
            fresh['id'] != userId ||
            (isCurrent != null && !isCurrent())) {
          throw StateError('session_changed');
        }
        if (_sessionScope == null) {
          await prefs.setString('user', jsonEncode(fresh));
        } else {
          onFresh?.call(fresh);
        }
        return HomeUserProfile.fromMap(fresh);
      }
    } catch (e) {
      debugPrint('[home] get_my_profile failed: $e');
    }

    if (fallback != null) return fallback;
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
          .eq('user_id', userId)
          .timeout(const Duration(seconds: 12));
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
      final todayLessons =
          await _scheduleRepository.loadRange(today, days: 1, strict: true);
      return todayLessons
          .where((lesson) => MskDate.isSameCalendarDate(lesson.date, today))
          .toList()
        ..sort(_compareLessons);
    } catch (e) {
      debugPrint('[home] today lessons failed: $e');
      rethrow;
    }
  }

  Future<List<HomeAssignmentPreview>> _loadAssignments(
      {bool Function()? isCurrent}) async {
    try {
      final teams = await _learningRepository.loadTeams('', strict: true);
      if (isCurrent != null && !isCurrent()) throw HomeLoadCancelled();
      final previews = <HomeAssignmentPreview>[];

      final selected = teams.take(8).toList();
      for (var start = 0; start < selected.length; start += 4) {
        if (isCurrent != null && !isCurrent()) throw HomeLoadCancelled();
        final batches = await Future.wait(
            selected.skip(start).take(4).map(_loadTeamAssignments));
        if (isCurrent != null && !isCurrent()) throw HomeLoadCancelled();
        for (final batch in batches) {
          previews.addAll(batch);
        }
      }

      previews.sort(_compareAssignments);
      return previews;
    } catch (e) {
      debugPrint('[home] assignments failed: $e');
      rethrow;
    }
  }

  Future<List<HomeAssignmentPreview>> _loadTeamAssignments(Team team) async {
    try {
      final assignments =
          await _learningRepository.loadAssignments(team.id, strict: true);
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
      rethrow;
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

class HomeLoadCancelled extends StateError {
  HomeLoadCancelled() : super('session_changed');
}

/// Persists the published news feed for cache-first / stale-while-revalidate.
///
/// Only the JSON returned by `get_my_published_news` is stored (never image
/// bytes). Cache is never cleared on network error.
class PublishedNewsCache {
  PublishedNewsCache({
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId;

  final Future<SharedPreferences> Function() _prefs;
  final String? Function()? _currentUserId;

  static const String keyPrefix = 'home_published_news_v1';

  String _keyFor(String? userId) {
    final id = (userId ?? '').trim();
    if (id.isEmpty) return '${keyPrefix}__anon';
    return '${keyPrefix}__$id';
  }

  Future<List<HomeNewsItem>> read(
      {String? owner, bool Function()? isCurrent}) async {
    try {
      final userId = owner ?? _currentUserId?.call();
      final prefs = await _prefs();
      if ((_currentUserId != null && _currentUserId() != userId) ||
          !(isCurrent?.call() ?? true)) return const [];
      final raw = prefs.getString(_keyFor(userId));
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

  Future<void> write(List<Map<String, dynamic>> rows,
      {String? owner, bool Function()? isCurrent}) async {
    try {
      final userId = owner ?? _currentUserId?.call();
      final prefs = await _prefs();
      if ((_currentUserId != null && _currentUserId() != userId) ||
          !(isCurrent?.call() ?? true)) return;
      await prefs.setString(_keyFor(userId), jsonEncode(rows));
    } catch (e) {
      debugPrint('[home] news cache write failed: $e');
    }
  }

  /// Drop cached feeds for every user on this device (logout / account switch).
  Future<void> clearAll() async {
    try {
      final prefs = await _prefs();
      final keys = prefs.getKeys().where((k) => k.startsWith(keyPrefix));
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (e) {
      debugPrint('[home] news cache clear failed: $e');
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
