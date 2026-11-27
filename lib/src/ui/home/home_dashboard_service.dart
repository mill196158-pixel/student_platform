import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_group_actions.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/home/news_cover_http_client.dart'
    if (dart.library.io) 'package:student_platform/src/ui/home/news_cover_http_client_io.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_prewarm.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/transport_failure.dart';
import 'package:student_platform/src/ui/home/home_frame_trace.dart';

class HomeDashboardService {
  HomeDashboardService({
    SupabaseClient? client,
    ScheduleRepository? scheduleRepository,
    SupabaseLearningRepository? learningRepository,
    PublishedNewsCache? newsCache,
    NewsImageDiskCache? imageCache,
    PublicNewsImageCache? publicImageCache,
    http.Client? httpClient,
    AuthSessionScope? sessionScope,
    HomeSnapshotCache? snapshotCache,
    HomeSnapshotCache? projectSnapshotCache,
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
        _projectSnapshotCache = projectSnapshotCache ??
            _createProjectSnapshotCache(
                client ?? Supabase.instance.client, sessionScope),
        _scheduleRepository = scheduleRepository ?? ScheduleRepository(),
        _learningRepository =
            learningRepository ?? SupabaseLearningRepository(),
        _newsCache = newsCache ??
            PublishedNewsCache(
              currentUserId: () =>
                  (client ?? Supabase.instance.client).auth.currentUser?.id,
            ),
        _publicImages = publicImageCache ??
            (imageCache == null ? PublicNewsImageCache.shared : PublicNewsImageCache(legacy: imageCache)),
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  static HomeSnapshotCache? _createProjectSnapshotCache(
      SupabaseClient client, AuthSessionScope? scope) {
    if (scope == null) return null;
    AuthOperationScope? currentOwner() {
      try {
        if (!identical(client, Supabase.instance.client)) return null;
        final owner = scope.capture();
        if (owner == null ||
            !scope.matchesSession(owner, client.auth.currentSession))
          return null;
        final issuer =
            '${SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '')}/auth/v1';
        final binding = scope.bindingFor(owner, issuer);
        if (binding == null ||
            binding.issuer != issuer ||
            binding.userId != owner.userId) return null;
        return owner;
      } catch (_) {
        return null;
      }
    }

    return HomeSnapshotCache(
      currentUserId: () => currentOwner()?.userId,
      sessionGeneration: () => scope.generation,
      sessionIdentity: currentOwner,
      project: SupabaseConfig.url,
      authScope: scope,
    );
  }

  String? get currentUserId => _sb.auth.currentUser?.id;

  Future<void> prewarmSchedule(OnlineSideEffectBarrier barrier) async {
    final scope = _sessionScope;
    if (_disposed || scope == null || !barrier.isOpen) return;
    await scope.ready;
    if (_disposed || !barrier.isOpen) return;
    final cache = ScheduleMonthCache(scope, SupabaseConfig.url);
    await SchedulePrewarm(
            scope: scope,
            cache: cache,
            barrier: barrier,
            loadMonth: (month) => _scheduleRepository.loadMonthForPrewarm(month,
                isCurrent: () => !_disposed && barrier.isOpen))
        .warm(MskDate.today());
  }

  final SupabaseClient _sb;
  final ScheduleRepository _scheduleRepository;
  final SupabaseLearningRepository _learningRepository;
  final PublishedNewsCache _newsCache;
  final PublicNewsImageCache _publicImages;
  @visibleForTesting
  PublicNewsImageCache get debugPublicImageCache => _publicImages;
  final http.Client _http;
  final bool _ownsHttpClient;
  final AuthSessionScope? _sessionScope;
  final HomeSnapshotCache? _snapshotCache;
  final HomeSnapshotCache? _projectSnapshotCache;
  final _preparedCovers = <String, (NewsImageCacheKey, (int, int), Uint8List)>{};
  (String?, int?)? _preparedCoverOwner;
  bool _disposed = false;
  int _loadRevision = 0;

  void dispose() {
    _disposed = true;
    _loadRevision++;
    _preparedCovers.clear();
    if (_ownsHttpClient) _http.close();
  }

  /// Instant cache-first news (JSON + previously saved image bytes).
  /// Never hits the network.
  Future<List<HomeNewsItem>> loadCachedNews() async {
    final cached = await _newsCache.read();
    if (cached.isEmpty) return const [];
    return _hydrateImagesFromDisk(cached);
  }

  Future<List<HomeNewsItem>> validateNewsImages(List<HomeNewsItem> items) =>
      _hydrateImagesFromDisk(items);

  Future<HomeDashboardData> load({
    void Function(HomeDashboardData)? onUpdate,
    HomeDashboardData? previous,
  }) async {
    final trace = HomeFrameTrace();
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
    final coverOwner = (userId, source?.generation);
    if (coverOwner != _preparedCoverOwner) {
      _preparedCoverOwner = coverOwner;
      _preparedCovers.clear();
    }
    final cache = _snapshotCache;
    final cacheScope = userId == null ? null : cache?.captureScope(userId);
    final projectCache = _projectSnapshotCache;
    final projectScope =
        userId == null ? null : projectCache?.captureScope(userId);
    void writeProjectSnapshot(
        HomeSnapshotSection section, List<Map<String, dynamic>> items,
        {String? date}) {
      if (!current() ||
          projectCache == null ||
          projectScope == null ||
          !projectCache.isCurrent(projectScope)) return;
      unawaited(projectCache
          .write(
              scope: projectScope,
              section: section,
              items: items,
              date: date,
              savedAt: DateTime.now())
          .catchError((Object _) => false));
    }

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
    var initialNewsRead = validPrevious != null;
    var initialSectionsRead = validPrevious != null;
    var newsLoading = validPrevious?.newsLoading ?? true;
    var actions = validPrevious?.groupActions ?? <HomeGroupActionPreview>[];
    String? scheduleStatus = validPrevious?.isScheduleForToday == true
        ? validPrevious!.scheduleStatus
        : 'Загружаем расписание…';
    String? assignmentsStatus = validPrevious == null
        ? 'Загружаем ближайшие дела…'
        : validPrevious.assignmentsStatus;
    var scheduleFromCache = false;
    var assignmentsFromCache = false;
    var profileFromCache = false;
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
        newsLoading: newsLoading,
        readNotificationIds: reads,
        groupActions: actions.take(4).toList());
    void publish() {
      if (initialSectionsRead && initialNewsRead && current()) {
        onUpdate?.call(snapshot());
      }
    }

    var profileConfirmed = false;
    var scheduleConfirmed = false;
    // Read the local sections together for the first frame. Server requests
    // still run independently and a late local read cannot replace fresh data.
    final cacheReads = <Future<void>>[];
    if (validPrevious == null &&
        cache != null && cacheScope != null && userId != null) {
      Future<void> restore(HomeSnapshotSection section,
          void Function(HomeSectionSnapshot) apply) async {
        try {
          final saved = await cache.read(userId, section)
              .timeout(const Duration(seconds: 1), onTimeout: () => null);
          trace.mark('home_local_${section.name}', counts: {
            'rows': saved?.items.length ?? 0,
          });
          if (saved == null || !current() || !cache.isCurrent(cacheScope)) return;
          apply(saved);
        } catch (_) {
          // A cache failure affects only its own section.
        }
      }

      cacheReads.addAll([
        restore(HomeSnapshotSection.schedule, (saved) {
          if (scheduleConfirmed || saved.date != MskDate.isoDate(scheduleDate)) return;
          final decoded = saved.items.map(HomeSnapshotCodec.lessonFromMap).toList();
          if (decoded.any((item) => item == null)) return;
          lessons = decoded.cast<Lesson>();
          scheduleStatus = 'Сохранённое расписание';
          scheduleFromCache = true;
          publish();
        }),
        restore(HomeSnapshotSection.assignments, (saved) {
          if (assignmentsReady) return;
          final decoded =
              saved.items.map(HomeSnapshotCodec.assignmentFromMap).toList();
          if (decoded.any((item) => item == null)) return;
          assignments = decoded.cast<HomeAssignmentPreview>();
          assignmentsStatus = 'Сохранённые задания';
          assignmentsFromCache = true;
          publish();
        }),
        restore(HomeSnapshotSection.profile, (saved) {
          if (profileConfirmed || saved.items.length != 1 ||
              saved.items.first['id'] != userId) return;
          profile = HomeUserProfile.fromMap(saved.items.first);
          profileFromCache = true;
          publish();
        }),
      ]);
    }
    final localSections = Future.wait(cacheReads).then((_) {
      initialSectionsRead = true;
      publish();
    });

    final profileWork = _loadProfile(
        isCurrent: current,
        fallback: profile.id == userId ? profile : null,
        onFresh: (fresh) {
          if (!current()) return;
          profileConfirmed = true;
          writeProjectSnapshot(HomeSnapshotSection.profile, [fresh]);
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
          if (!current() || profileFromCache) return;
          profile = cached;
          publish();
        }).then((value) {
      if (!current() || (!profileConfirmed && profile.id == userId)) return;
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
      writeProjectSnapshot(HomeSnapshotSection.assignments,
          value.take(4).map(HomeSnapshotCodec.assignmentToMap).toList());
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
      if (validPrevious == null) {
        assignmentsStatus = assignmentsFromCache
            ? 'Сохранённые задания'
            : 'Не удалось обновить задания';
      }
      publish();
    });
    await Future.wait<void>([
      localSections,
      profileWork,
      assignmentsWork,
      _loadTodayLessons(scheduleDate).timeout(const Duration(seconds: 15)).then(
          (value) {
        if (!current()) return;
        lessons = value;
        scheduleConfirmed = true;
        scheduleFromCache = false;
        scheduleStatus = null;
        publish();
        writeProjectSnapshot(HomeSnapshotSection.schedule,
            value.map(HomeSnapshotCodec.lessonToMap).toList(),
            date: MskDate.isoDate(scheduleDate));
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
        if (validPrevious?.isScheduleForToday != true) {
          scheduleStatus = scheduleFromCache
              ? 'Сохранённое расписание'
              : 'Не удалось обновить расписание';
        }
        publish();
      }),
      _loadReadNotificationIds().then((value) {
        reads = value;
        publish();
      }),
      _loadPublishedNews(
          previous: news,
          readLocalFirst: validPrevious == null,
          isCurrent: current,
          onLocalReady: (value) {
            if (!current()) return;
            trace.mark('home_local_news', counts: {
              'rows': value.length,
              'savedFiles': value.where((item) => item.imageBytes != null).length,
            });
            initialNewsRead = true;
            news = value;
            publish();
          },
          onMetadata: (value) {
            news = value;
            newsLoading = false;
            publish();
          }),
      _loadGroupActionDeadlines().timeout(const Duration(seconds: 15)).then(
          (value) {
        actions = value;
        actionsReady = true;
        updateAssignmentStatus();
        publish();
      }, onError: (Object error) {
        if (!isTemporaryTransportFailure(error)) actions = [];
        if (validPrevious == null) {
          assignmentsStatus = assignmentsFromCache
              ? 'Сохранённые задания'
              : 'Не удалось обновить ближайшие дела';
        }
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
  /// - Refresh keeps an already-authorized cover for the same publication and
  ///   media path, then independently verifies any newer disk cache version.
  Future<void> _loadPublishedNews({
    List<HomeNewsItem> previous = const [],
    required bool readLocalFirst,
    required void Function(List<HomeNewsItem>) onLocalReady,
    required void Function(List<HomeNewsItem>) onMetadata,
    bool Function()? isCurrent,
  }) async {
    final newsUser = _sb.auth.currentUser?.id;
    bool current() =>
        _sb.auth.currentUser?.id == newsUser && (isCurrent?.call() ?? true);

    Future<List<Map<String, dynamic>>?> refresh() async {
      try {
        final response = await _sb
            .rpc('get_my_published_news')
            .timeout(const Duration(seconds: 12));
        final payload = response is String ? jsonDecode(response) : response;
        if (payload is! List || payload.any((row) => row is! Map)) {
          throw const FormatException('Unexpected news publication result');
        }
        final rows = payload.map((row) => Map<String, dynamic>.from(row as Map))
            .toList();
        if (rows.length > 1) rows.sort(_comparePublishedNews);
        return current() ? rows : null;
      } catch (e) {
        debugPrint('[home] published news failed: $e');
        return null;
      }
    }

    final refreshing = refresh();
    final local = readLocalFirst
        ? await _loadVisibleCachedNews(newsUser, current)
        : _retainCurrentCovers(previous);
    if (!current()) return;
    onLocalReady(local);
    final rows = await refreshing;
    if (!current()) return;
    if (rows == null) {
      onMetadata(local.isEmpty && _sessionScope == null ? _localNews() : local);
      if (local.isEmpty) return;
      unawaited(_hydrateImagesFromDisk(local, keepPrepared: true, current: current)
          .then((items) {
        if (current()) onMetadata(items);
      }));
      return;
    }
    final fresh = rows.map(mapPublishedNews).toList();
    final paths = {
      for (final item in fresh)
        if (item.usesImage) item.id: item.imageCacheKey?.path,
    };
    _preparedCovers.removeWhere((id, cover) => paths[id] != cover.$1.path);
    await _newsCache.write(rows,
        owner: newsUser,
        isCurrent: current,
        savedCoverVersions: {
          for (final item in fresh)
            if (_preparedCovers[item.id] case final cover?
                when cover.$1.path == item.imageCacheKey?.path &&
                    cover.$1.version != item.imageCacheKey?.version &&
                    cover.$2 == _publicImages.displayVersion(cover.$1))
              (item.id, cover.$1.path): cover.$1.version,
        });
    if (!current()) return;
    final prior = {for (final item in local) item.id: item};
    final merged = _retainCurrentCovers([
      for (final item in fresh)
        item.copyWith(imageBytes: prior[item.id]?.imageBytes),
    ]);
    onMetadata(merged);
    // Media owns its own deadlines; a late successful cover can refine the
    // publication without replacing the rest of the dashboard.
    unawaited(_resolveNewsImages(merged, current: current, onImage: (items) {
      if (current()) onMetadata(items);
    }));
  }

  Future<List<HomeNewsItem>> _loadVisibleCachedNews(
      String? owner, bool Function() current) async {
    var cached = <HomeNewsItem>[];
    final ready = <int, HomeNewsItem>{};
    final savedCoverVersions = <(String, String), String>{};
    var accepting = true;
    return (() async {
      cached = await _newsCache.read(
        owner: owner,
        isCurrent: current,
        onSavedCoverVersion: (post, version) => savedCoverVersions[post] = version,
      );
      if (!accepting || !current() || cached.isEmpty) return const <HomeNewsItem>[];
      final first = await _hydrateImagesFromDisk(cached.take(4).toList(),
        keepPrepared: true,
        current: () => accepting && current(),
        onReady: (index, item) => ready[index] = item,
        savedCoverVersions: savedCoverVersions,
      );
      return [...first, ...cached.skip(4)];
    })().timeout(const Duration(seconds: 1), onTimeout: () {
      accepting = false;
      return [for (var index = 0; index < cached.length; index++) ready[index] ?? cached[index]];
    });
  }

  List<HomeNewsItem> _retainCurrentCovers(List<HomeNewsItem> items) {
    return items.map((item) {
      final key = item.imageCacheKey;
      if (key != null && _preparedCover(item, key, allowPreviousVersion: true)) return item;
      return item.imageBytes == null ? item : item.copyWith(clearImageBytes: true);
    }).toList();
  }

  bool _preparedCover(HomeNewsItem item, NewsImageCacheKey key,
      {bool allowPreviousVersion = false}) {
    final known = _preparedCovers[item.id];
    return known != null && known.$1.path == key.path &&
        (allowPreviousVersion || known.$1.version == key.version) &&
        known.$2 == _publicImages.displayVersion(key) &&
        identical(known.$3, item.imageBytes);
  }

  Future<List<HomeNewsItem>> _hydrateImagesFromDisk(
    List<HomeNewsItem> items, {
    bool keepPrepared = false,
    bool Function()? current,
    void Function(int, HomeNewsItem)? onReady,
    Map<(String, String), String> savedCoverVersions = const {},
  }) async {
    final out = List<HomeNewsItem>.of(items);
    var next = 0;
    Future<void> worker() async {
      while (next < items.length && current?.call() != false) {
        final index = next++;
        final item = items[index];
        final key = item.imageCacheKey;
        if (keepPrepared && key != null && _preparedCover(item, key)) {
          onReady?.call(index, item);
          continue;
        }
        if (key == null || !keepPrepared ||
            !_preparedCover(item, key, allowPreviousVersion: true)) {
          out[index] = item.copyWith(clearImageBytes: true);
        }
        if (key == null) continue;
        try {
          final preloaded = item.imageBytes;
          final version = _publicImages.displayVersion(key);
          var storedKey = key;
          var result = await _publicImages.read(key,
              legacyFallback: preloaded == null || keepPrepared
                  ? null : () async => preloaded);
          final savedVersion = savedCoverVersions[(item.id, key.path)];
          if (result.state == NewsImageReadState.miss && savedVersion != null &&
              savedVersion != key.version && current?.call() != false &&
              version == _publicImages.displayVersion(key)) {
            storedKey = NewsImageCacheKey(path: key.path, version: savedVersion);
            result = await _publicImages.read(storedKey);
          }
          if (result.state != NewsImageReadState.hit ||
              version != _publicImages.displayVersion(key) ||
              current?.call() == false) continue;
          final bytes = listEquals(out[index].imageBytes, result.bytes)
              ? out[index].imageBytes! : result.bytes!;
          if (keepPrepared) _preparedCovers[item.id] = (storedKey, version, bytes);
          out[index] = item.copyWith(imageBytes: bytes);
          onReady?.call(index, out[index]);
        } catch (_) {
          // One damaged cache entry must not hide the remaining news.
        }
      }
    }

    await Future.wait(List.generate(items.length.clamp(0, 4), (_) => worker()));
    return out;
  }

  Future<List<HomeNewsItem>> _resolveNewsImages(
    List<HomeNewsItem> items, {
    required bool Function() current,
    void Function(List<HomeNewsItem>)? onImage,
  }) async {
    final resolved = List<HomeNewsItem>.from(items);
    var next = 0;
    Future<void> worker() async {
      while (next < resolved.length && current()) {
        final index = next++;
        final item = resolved[index];
        final key = item.imageCacheKey;
        if (key == null || _preparedCover(item, key)) continue;
        try {
          final version = _publicImages.displayVersion(key);
          final bytes = await _fetchNewsImage(key);
          if (!current() || bytes == null || bytes.isEmpty ||
              version != _publicImages.displayVersion(key)) continue;
          final previous = item.imageBytes;
          if (previous != null && listEquals(previous, bytes)) {
            _preparedCovers[item.id] = (key, version, previous);
          } else {
            _preparedCovers[item.id] = (key, version, bytes);
            resolved[index] = item.copyWith(imageBytes: bytes);
            onImage?.call(List<HomeNewsItem>.unmodifiable(resolved));
          }
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
    return _fetchNewsImage(key);
  }

  Future<Uint8List?> resolveGuardedStoryImage(
      HomeNewsItem item, OnlineSideEffectBarrier barrier,
      {required bool Function() current}) async {
    final key = item.imageCacheKey;
    if (key == null || !current()) return null;
    final cached = await _publicImages.read(key);
    if (!current()) return null;
    if (cached.state == NewsImageReadState.hit) return cached.bytes;
    final result = await barrier.run(() async =>
        (bytes: await _downloadGuardedStoryImage(key.path, barrier, current)));
    return current() ? result?.bytes : null;
  }

  Future<Uint8List?> _downloadGuardedStoryImage(
    String path,
    OnlineSideEffectBarrier barrier,
    bool Function() current,
  ) async {
    final session = _sb.auth.currentSession;
    final apiKey = _sb.auth.headers['apikey'];
    if (!current() || session == null || apiKey == null) return null;
    final project = Uri.parse(_sb.rest.url);
    if (project.scheme != 'https' || project.userInfo.isNotEmpty) return null;
    final client = _ownsHttpClient ? createNewsCoverHttpClient() : _http;
    final abort = Completer<void>();
    void stop() {
      if (abort.isCompleted) return;
      abort.complete();
      if (_ownsHttpClient) client.close();
    }

    final unregister = barrier.onClose(stop);
    final timeout = Timer(const Duration(seconds: 12), stop);
    try {
      if (!current() || abort.isCompleted) return null;
      final signing = http.AbortableRequest(
        'POST', project.resolve('/functions/v1/news-media'),
        abortTrigger: abort.future,
      )
        ..followRedirects = false
        ..headers.addAll({
          'apikey': apiKey,
          'Authorization': 'Bearer ${session.accessToken}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({'action': 'createDownload', 'path': path});
      final signed = await http.Response.fromStream(await client.send(signing));
      if (!current() || abort.isCompleted || signed.statusCode != 200) return null;
      final data = jsonDecode(signed.body);
      final value = data is Map ? data['signedUrl'] : null;
      final url = value is String ? Uri.tryParse(value) : null;
      if (url == null || url.userInfo.isNotEmpty || url.origin != project.origin) {
        return null;
      }
      final downloading = http.AbortableRequest('GET', url, abortTrigger: abort.future)
        ..followRedirects = false;
      final download = await client.send(downloading);
      if (!current() || download.statusCode != 200) {
        await download.stream.listen(null).cancel();
        return null;
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in download.stream) {
        if (!current() || abort.isCompleted || buffer.length + chunk.length > 8 * 1024 * 1024) {
          return null;
        }
        buffer.add(chunk);
      }
      return buffer.isEmpty || !current() ? null : buffer.takeBytes();
    } catch (_) {
      return null;
    } finally {
      unregister();
      timeout.cancel();
      stop();
    }
  }

  Future<Uint8List?> _fetchNewsImage(NewsImageCacheKey key) {
    return _publicImages.getOrFetch(key, () => _downloadNewsImage(key.path));
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
      final download = await _http.get(Uri.parse(signedUrl))
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

  static int _comparePublishedNews(
      Map<String, dynamic> first, Map<String, dynamic> second) {
    int number(Map<String, dynamic> row, String key) =>
        int.tryParse(row[key]?.toString() ?? '') ?? 0;
    final byPosition =
        number(first, 'sort_order').compareTo(number(second, 'sort_order'));
    if (byPosition != 0) return byPosition;
    final byPriority =
        number(second, 'priority').compareTo(number(first, 'priority'));
    if (byPriority != 0) return byPriority;
    final firstDate = DateTime.tryParse(first['published_at']?.toString() ?? '');
    final secondDate = DateTime.tryParse(second['published_at']?.toString() ?? '');
    if (firstDate != null && secondDate != null) {
      final byDate = secondDate.compareTo(firstDate);
      if (byDate != 0) return byDate;
    } else if (firstDate != null || secondDate != null) {
      return firstDate == null ? 1 : -1;
    }
    return (first['id']?.toString() ?? '')
        .compareTo(second['id']?.toString() ?? '');
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
        }
        onFresh?.call(fresh);
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
/// Stores owner-scoped published metadata and an optional local cover version.
/// The encoded images remain in the versioned public news image cache.
class PublishedNewsCache {
  PublishedNewsCache({
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId;

  final Future<SharedPreferences> Function() _prefs;
  final String? Function()? _currentUserId;

  static const String keyPrefix = 'home_published_news_v1';
  static const _savedCoverVersionField = '_saved_cover_version';

  String _keyFor(String? userId) {
    final id = (userId ?? '').trim();
    if (id.isEmpty) return '${keyPrefix}__anon';
    return '${keyPrefix}__$id';
  }

  Future<List<HomeNewsItem>> read(
      {String? owner, bool Function()? isCurrent,
      void Function((String, String), String)? onSavedCoverVersion}) async {
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
            .map((e) {
              final item = mapPublishedNews(Map<String, dynamic>.from(e));
              final version = e[_savedCoverVersionField];
              final path = item.imageCacheKey?.path;
              if (item.usesImage && version is String && path != null) {
                onSavedCoverVersion?.call((item.id, path), version);
              }
              return item;
            })
            .toList();
      }
    } catch (e) {
      debugPrint('[home] news cache read failed: $e');
    }
    return const [];
  }

  Future<void> write(List<Map<String, dynamic>> rows,
      {String? owner, bool Function()? isCurrent,
      Map<(String, String), String> savedCoverVersions = const {}}) async {
    try {
      final userId = owner ?? _currentUserId?.call();
      final prefs = await _prefs();
      if ((_currentUserId != null && _currentUserId() != userId) ||
          !(isCurrent?.call() ?? true)) return;
      final toSave = [
        for (final row in rows)
          {
            for (final entry in row.entries)
              if (entry.key != _savedCoverVersionField) entry.key: entry.value,
            if (savedCoverVersions[(row['id']?.toString() ?? '',
                row['image_path']?.toString().trim() ?? '')] case final version?)
              _savedCoverVersionField: version,
          },
      ];
      await prefs.setString(_keyFor(userId), jsonEncode(toSave));
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
