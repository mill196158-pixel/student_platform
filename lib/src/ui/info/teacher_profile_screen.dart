import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TeacherProfileScreen extends StatefulWidget {
  final String teacherName;
  final String? subjectTitle;
  final String? department;
  final int? semesterNumber;
  final double? difficultyScore;
  final String? subjectOfferingId;
  final double? subjectDifficultyAvg;

  const TeacherProfileScreen({
    super.key,
    required this.teacherName,
    this.subjectTitle,
    this.department,
    this.semesterNumber,
    this.difficultyScore,
    this.subjectOfferingId,
    this.subjectDifficultyAvg,
  });

  @override
  State<TeacherProfileScreen> createState() => _TeacherProfileScreenState();
}

class _TeacherProfileScreenState extends State<TeacherProfileScreen> {
  final _repository = _TeacherDifficultyRepository();
  _TeacherDifficultySnapshot? _rating;
  bool _ratingLoading = true;
  bool _ratingSubmitting = false;
  double? _subjectDifficultyAvg;

  @override
  void initState() {
    super.initState();
    _subjectDifficultyAvg = widget.subjectDifficultyAvg;
    _loadRating();
    _loadSubjectDifficulty();
  }

  Future<void> _loadRating() async {
    final cached = await _repository.loadCached(widget.teacherName);
    if (cached != null && mounted) {
      setState(() {
        _rating = cached;
        _ratingLoading = false;
      });
    }

    try {
      final rating = await _repository.load(widget.teacherName);
      if (!mounted) return;
      setState(() {
        _rating = rating;
        _ratingLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _ratingLoading = false);
    }
  }

  Future<void> _loadSubjectDifficulty() async {
    if (_subjectDifficultyAvg != null && _subjectDifficultyAvg! > 0) return;
    final offeringId = (widget.subjectOfferingId ?? '').trim();
    if (offeringId.isEmpty) return;
    try {
      final avg = await _repository.loadSubjectDifficultyAvg(offeringId);
      if (!mounted || avg == null) return;
      setState(() => _subjectDifficultyAvg = avg);
    } catch (_) {}
  }

  Future<void> _vote(int score) async {
    final teacherId = _rating?.teacherId;
    if (teacherId == null || _ratingSubmitting) return;

    setState(() => _ratingSubmitting = true);
    try {
      await _repository.vote(teacherId: teacherId, score: score);
      final rating = await _repository.load(widget.teacherName);
      if (!mounted) return;
      _repository.announceRatingChanged();
      setState(() {
        _rating = rating;
        _ratingSubmitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _ratingSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить оценку')),
      );
    }
  }

  void _showRatingSheet() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _TeacherRatingSheet(
        myScore: _rating?.myScore,
        onVote: (score) {
          Navigator.of(sheetContext).pop();
          _vote(score);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _clean(widget.teacherName) ?? 'Преподаватель';
    final subject = _clean(widget.subjectTitle);
    final departmentName = _clean(widget.department);
    final averageScore = _rating?.averageScore ?? widget.difficultyScore;
    final difficulty = _TeacherDifficultyPresentation.fromScore(averageScore);
    final media = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFFBFAFF),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.zero,
            children: [
              _TeacherHero(
                topPadding: media.padding.top,
                name: name,
                department: departmentName,
                difficulty: difficulty,
                averageScore: averageScore,
                voteCount: _rating?.voteCount ?? 0,
                myScore: _rating?.myScore,
                ratingLoading: _ratingLoading || _ratingSubmitting,
                canVote: _rating?.teacherId != null,
                onRate: _showRatingSheet,
              ),
              const SizedBox(height: 14),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  28 + media.padding.bottom,
                ),
                child: Column(
                  children: [
                    if (_rating?.aboutOrNull != null) ...[
                      _ProfileCard(
                        icon: Icons.info_outline_rounded,
                        title: 'О преподавателе',
                        compact: true,
                        child: _AboutTeacherBlock(
                          text: _rating!.aboutOrNull!,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (subject != null)
                      _ProfileCard(
                        icon: Icons.auto_stories_outlined,
                        title: 'Предмет',
                        compact: true,
                        child: _SubjectRow(
                          title: subject,
                          semesterNumber: widget.semesterNumber,
                          subjectDifficultyAvg: _subjectDifficultyAvg,
                        ),
                      ),
                    if (subject != null) const SizedBox(height: 10),
                    const _ProfileCard(
                      icon: Icons.forum_outlined,
                      title: 'Отзывы студентов',
                      compact: true,
                      child: _ReviewsPausedState(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          PositionedDirectional(
            start: 4,
            top: media.padding.top + 4,
            child: const _TopBackButton(),
          ),
        ],
      ),
    );
  }

  static String? _clean(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty ? null : text;
  }
}

class _TeacherDifficultySnapshot {
  final String? teacherId;
  final double? averageScore;
  final int voteCount;
  final int? myScore;
  final String? aboutText;

  const _TeacherDifficultySnapshot({
    required this.teacherId,
    required this.averageScore,
    required this.voteCount,
    required this.myScore,
    this.aboutText,
  });

  String? get aboutOrNull {
    final text = (aboutText ?? '').trim();
    return text.isEmpty ? null : text;
  }
}

class _TeacherDifficultyRepository {
  _TeacherDifficultyRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;
  static final Map<String, _TeacherDifficultySnapshot> _memoryCache = {};
  static final ValueNotifier<int> ratingRevision = ValueNotifier<int>(0);

  void announceRatingChanged() {
    ratingRevision.value++;
  }

  String _normalizedName(String teacherName) =>
      teacherName.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  String _cacheKey(String teacherName) {
    final user = _client.auth.currentUser?.id ?? 'anonymous';
    return 'teacher_difficulty_v3:$user:${_normalizedName(teacherName)}';
  }

  Future<_TeacherDifficultySnapshot?> loadCached(String teacherName) async {
    final key = _cacheKey(teacherName);
    final memoryValue = _memoryCache[key];
    if (memoryValue != null) return memoryValue;

    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final snapshot = _TeacherDifficultySnapshot(
        teacherId: json['teacherId'] as String?,
        averageScore: (json['averageScore'] as num?)?.toDouble(),
        voteCount: _asInt(json['voteCount']),
        myScore: json['myScore'] == null ? null : _asInt(json['myScore']),
        aboutText: (json['aboutText'] as String?)?.trim(),
      );
      _memoryCache[key] = snapshot;
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCached(
    String teacherName,
    _TeacherDifficultySnapshot snapshot,
  ) async {
    final key = _cacheKey(teacherName);
    _memoryCache[key] = snapshot;
    final raw = jsonEncode({
      'teacherId': snapshot.teacherId,
      'averageScore': snapshot.averageScore,
      'voteCount': snapshot.voteCount,
      'myScore': snapshot.myScore,
      'aboutText': snapshot.aboutText,
    });
    await (await SharedPreferences.getInstance()).setString(key, raw);
  }

  Future<_TeacherDifficultySnapshot> load(String teacherName) async {
    final normalizedName = _normalizedName(teacherName);
    if (normalizedName.isEmpty) {
      const snapshot = _TeacherDifficultySnapshot(
        teacherId: null,
        averageScore: null,
        voteCount: 0,
        myScore: null,
        aboutText: null,
      );
      await _saveCached(teacherName, snapshot);
      return snapshot;
    }

    final target = await _client
        .from('teacher_difficulty_targets')
        .select('id, about_text')
        .eq('normalized_name', normalizedName)
        .maybeSingle();
    final teacherId = (target?['id'] ?? '').toString().trim();
    final aboutText = (target?['about_text'] ?? '').toString().trim();
    if (teacherId.isEmpty) {
      const snapshot = _TeacherDifficultySnapshot(
        teacherId: null,
        averageScore: null,
        voteCount: 0,
        myScore: null,
        aboutText: null,
      );
      await _saveCached(teacherName, snapshot);
      return snapshot;
    }

    final summary = await _client
        .from('teacher_difficulty_summaries')
        .select('vote_count,score_total')
        .eq('teacher_id', teacherId)
        .maybeSingle();
    final voteCount = _asInt(summary?['vote_count']);
    final scoreTotal = _asInt(summary?['score_total']);

    int? myScore;
    final userId = _client.auth.currentUser?.id;
    if (userId != null) {
      final ownVote = await _client
          .from('teacher_difficulty_votes')
          .select('score')
          .eq('teacher_id', teacherId)
          .eq('user_id', userId)
          .maybeSingle();
      final parsedScore = _asInt(ownVote?['score']);
      if (parsedScore >= 1 && parsedScore <= 5) myScore = parsedScore;
    }

    final snapshot = _TeacherDifficultySnapshot(
      teacherId: teacherId,
      averageScore: voteCount == 0 ? null : scoreTotal / voteCount,
      voteCount: voteCount,
      myScore: myScore,
      aboutText: aboutText.isEmpty ? null : aboutText,
    );
    await _saveCached(teacherName, snapshot);
    return snapshot;
  }

  Future<void> vote({
    required String teacherId,
    required int score,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Authentication required');
    if (score < 1 || score > 5) throw ArgumentError.value(score, 'score');

    await _client.from('teacher_difficulty_votes').upsert(
      {
        'teacher_id': teacherId,
        'user_id': userId,
        'score': score,
      },
      onConflict: 'teacher_id,user_id',
    );
  }

  Future<double?> loadSubjectDifficultyAvg(String subjectOfferingId) async {
    final wanted = subjectOfferingId.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    try {
      final res = await _client.rpc('rpc_get_my_subjects_v2');
      final rows = (res as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      for (final row in rows) {
        final id = (row['subject_offering_id'] ?? row['id'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (id != wanted) continue;
        final global = _asDouble(row['avg_difficulty_global']);
        final local = _asDouble(row['avg_difficulty_local']);
        final avg = global > 0 ? global : local;
        return avg > 0 ? avg : null;
      }
    } catch (_) {}
    return null;
  }

  static int _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString()) ?? 0;
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString().replaceAll(',', '.')) ?? 0;
  }
}

class _TeacherDifficultyPresentation {
  final int? level;
  final String assetPath;
  final String title;
  final String story;

  const _TeacherDifficultyPresentation({
    required this.level,
    required this.assetPath,
    required this.title,
    required this.story,
  });

  bool get isKnown => level != null;

  static _TeacherDifficultyPresentation fromScore(double? score) {
    if (score == null || score <= 0) {
      return const _TeacherDifficultyPresentation(
        level: null,
        assetPath: 'assets/images/teacher_difficulty/unknown.png',
        title: 'Гость из мультивселенной',
        story: 'Сложность пока неизвестна — личность героя ещё скрыта.',
      );
    }

    final scoreLevel = score.clamp(1, 5).round();
    return switch (scoreLevel) {
      5 => const _TeacherDifficultyPresentation(
          level: 1,
          assetPath: 'assets/images/teacher_difficulty/level_1.png',
          title: 'Дружелюбный сосед',
          story: 'Сдавать легко: помогает разобраться и спокойно принимает.',
        ),
      4 => const _TeacherDifficultyPresentation(
          level: 2,
          assetPath: 'assets/images/teacher_difficulty/level_2.png',
          title: 'Защитник студентов',
          story: 'Скорее легко: требования понятные и справедливые.',
        ),
      3 => const _TeacherDifficultyPresentation(
          level: 3,
          assetPath: 'assets/images/teacher_difficulty/level_3.png',
          title: 'Маг дедлайнов',
          story: 'Средняя сложность: нужно знать правила и готовиться.',
        ),
      2 => const _TeacherDifficultyPresentation(
          level: 4,
          assetPath: 'assets/images/teacher_difficulty/level_4.png',
          title: 'Железный экзаменатор',
          story: 'Сдавать тяжело: требователен и внимательно проверяет детали.',
        ),
      _ => const _TeacherDifficultyPresentation(
          level: 5,
          assetPath: 'assets/images/teacher_difficulty/level_5.png',
          title: 'Титан сессии',
          story: 'Очень тяжело: уверенно сдают только хорошо подготовленные.',
        ),
    };
  }
}

class _TeacherHero extends StatelessWidget {
  final double topPadding;
  final String name;
  final String? department;
  final _TeacherDifficultyPresentation difficulty;
  final double? averageScore;
  final int voteCount;
  final int? myScore;
  final bool ratingLoading;
  final bool canVote;
  final VoidCallback onRate;

  const _TeacherHero({
    required this.topPadding,
    required this.name,
    required this.department,
    required this.difficulty,
    required this.averageScore,
    required this.voteCount,
    required this.myScore,
    required this.ratingLoading,
    required this.canVote,
    required this.onRate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(18, topPadding + 8, 18, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEDE4FF), Color(0xFFF8F4FF), Colors.white],
        ),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(30),
        ),
        border: Border(
          bottom: BorderSide(
            color: const Color(0xFF6A4BBC).withValues(alpha: 0.08),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6A4BBC).withValues(alpha: 0.12),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          _DifficultyAvatar(difficulty: difficulty),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.black,
              fontWeight: FontWeight.w900,
              height: 1.08,
            ),
          ),
          if (department != null) ...[
            const SizedBox(height: 7),
            Text(
              department!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.black54,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (difficulty.isKnown) ...[
            const SizedBox(height: 10),
            _StatusPill(
              icon: Icons.auto_awesome_rounded,
              text: difficulty.title,
            ),
            const SizedBox(height: 8),
            Text(
              difficulty.story,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.black54,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            difficulty.isKnown
                ? '${averageScore!.toStringAsFixed(1)} из 5 · '
                    '$voteCount ${_votesWord(voteCount)}'
                : 'Сложность сдачи преподавателю пока не оценена',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.black54,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: canVote && !ratingLoading ? onRate : null,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              minimumSize: const Size(0, 38),
            ),
            icon: ratingLoading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.star_rounded, size: 18),
            label: Text(myScore == null ? 'Оценить' : 'Моя оценка: $myScore'),
          ),
        ],
      ),
    );
  }

  static String _votesWord(int count) {
    final mod100 = count % 100;
    final mod10 = count % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'оценок';
    if (mod10 == 1) return 'оценка';
    if (mod10 >= 2 && mod10 <= 4) return 'оценки';
    return 'оценок';
  }
}

class _DifficultyAvatar extends StatelessWidget {
  final _TeacherDifficultyPresentation difficulty;

  const _DifficultyAvatar({required this.difficulty});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFEDE4FF),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6A4BBC).withValues(alpha: 0.25),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipOval(
        child: _CenteredDifficultyImage(
          difficulty: difficulty,
          fallbackIconSize: 42,
        ),
      ),
    );
  }
}

class _CenteredDifficultyImage extends StatelessWidget {
  final _TeacherDifficultyPresentation difficulty;
  final double fallbackIconSize;

  const _CenteredDifficultyImage({
    required this.difficulty,
    required this.fallbackIconSize,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Transform.scale(
        scale: 1.16,
        child: Image.asset(
          difficulty.assetPath,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => ColoredBox(
            color: const Color(0xFFEDE4FF),
            child: Center(
              child: Icon(
                Icons.person_outline_rounded,
                color: const Color(0xFF6A4BBC),
                size: fallbackIconSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cached difficulty avatar used in compact teacher links.
class TeacherDifficultyAvatar extends StatefulWidget {
  final String teacherName;
  final double size;
  final double? initialScore;

  const TeacherDifficultyAvatar({
    super.key,
    required this.teacherName,
    this.size = 38,
    this.initialScore,
  });

  @override
  State<TeacherDifficultyAvatar> createState() =>
      _TeacherDifficultyAvatarState();
}

class _TeacherDifficultyAvatarState extends State<TeacherDifficultyAvatar> {
  final _repository = _TeacherDifficultyRepository();
  double? _score;

  @override
  void initState() {
    super.initState();
    _score = widget.initialScore;
    _TeacherDifficultyRepository.ratingRevision.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    _TeacherDifficultyRepository.ratingRevision.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    _load();
  }

  Future<void> _load() async {
    final cached = await _repository.loadCached(widget.teacherName);
    if (cached != null && mounted) {
      setState(() => _score = cached.averageScore);
    }
    try {
      final current = await _repository.load(widget.teacherName);
      if (mounted && current.averageScore != _score) {
        setState(() => _score = current.averageScore);
      }
    } catch (_) {
      // Keep the cached avatar visible while offline.
    }
  }

  @override
  Widget build(BuildContext context) {
    final difficulty = _TeacherDifficultyPresentation.fromScore(_score);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFEDE4FF),
        border: Border.all(
          color: const Color(0xFF6A4BBC).withValues(alpha: 0.14),
        ),
      ),
      child: ClipOval(
        child: _CenteredDifficultyImage(
          difficulty: difficulty,
          fallbackIconSize: widget.size * 0.45,
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  final bool compact;

  const _ProfileCard({
    required this.icon,
    required this.title,
    required this.child,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconSize = compact ? 30.0 : 36.0;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(compact ? 20 : 24),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: compact ? 12 : 18,
            offset: Offset(0, compact ? 5 : 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: iconSize,
                height: iconSize,
                decoration: BoxDecoration(
                  color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(compact ? 10 : 12),
                ),
                child: Icon(
                  icon,
                  color: const Color(0xFF6A4BBC),
                  size: compact ? 17 : 19,
                ),
              ),
              SizedBox(width: compact ? 8 : 10),
              Expanded(
                child: Text(
                  title,
                  style: (compact
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.titleMedium)
                      ?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 8 : 14),
          child,
        ],
      ),
    );
  }
}

class _AboutTeacherBlock extends StatelessWidget {
  final String text;

  const _AboutTeacherBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5FF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.black.withValues(alpha: 0.78),
          height: 1.28,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SubjectRow extends StatelessWidget {
  final String title;
  final int? semesterNumber;
  final double? subjectDifficultyAvg;

  const _SubjectRow({
    required this.title,
    required this.semesterNumber,
    this.subjectDifficultyAvg,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSubjectScore =
        subjectDifficultyAvg != null && subjectDifficultyAvg! > 0;
    final difficultyLabel = hasSubjectScore
        ? '${subjectDifficultyAvg!.toStringAsFixed(1)} / 5'
        : 'нет оценок';
    final semesterLabel =
        semesterNumber == null ? null : '$semesterNumber-й семестр';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5FF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF6A4BBC),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              title.substring(0, 1).toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 15,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.local_fire_department_rounded,
                      size: 14,
                      color: hasSubjectScore
                          ? const Color(0xFFE67E22)
                          : Colors.black38,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        'Сложность: $difficultyLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: hasSubjectScore
                              ? Colors.black87
                              : Colors.black45,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (semesterLabel != null) ...[
                      Text(
                        ' · ',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.black38,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        semesterLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.black45,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherRatingSheet extends StatelessWidget {
  final int? myScore;
  final ValueChanged<int> onVote;

  const _TeacherRatingSheet({
    required this.myScore,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: const BoxDecoration(
        color: Color(0xFFFBFAFF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Сложность сдачи преподавателю',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              color: Colors.black,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '1 звезда — очень тяжело, 5 звёзд — легко',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              5,
              (index) {
                final score = index + 1;
                final selected = myScore != null && score <= myScore!;
                return Padding(
                  padding: EdgeInsets.only(right: index == 4 ? 0 : 6),
                  child: InkResponse(
                    onTap: () => onVote(score),
                    radius: 28,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected
                            ? const Color(0xFFFFF1D6)
                            : const Color(0xFFF1ECFA),
                      ),
                      child: Icon(
                        selected
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: selected
                            ? const Color(0xFFFFA928)
                            : const Color(0xFF6A4BBC),
                        size: 28,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          Text(
            myScore == null
                ? 'Нажмите на звезду, чтобы сохранить оценку'
                : 'Текущая оценка: $myScore из 5',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.black45,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewsPausedState extends StatelessWidget {
  const _ReviewsPausedState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6FA),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.shield_outlined,
            color: Color(0xFF6A4BBC),
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Раздел готовится',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Отзывы появятся после подключения модерации.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _StatusPill({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF6A4BBC)),
          const SizedBox(width: 6),
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF6A4BBC),
                  fontWeight: FontWeight.w900,
                ),
          ),
        ],
      ),
    );
  }
}

class _TopBackButton extends StatelessWidget {
  const _TopBackButton();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.maybePop(context),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.arrow_back_rounded,
            color: Theme.of(context).colorScheme.onSurface,
            size: 24,
          ),
        ),
      ),
    );
  }
}
