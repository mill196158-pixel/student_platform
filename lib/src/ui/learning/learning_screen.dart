// =============================
// FILE: lib/src/ui/learning/learning_screen.dart
// =============================

import 'dart:ui' as ui; // для мягких свечений
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/data/academic_context_service.dart';
import 'state/learning_cubit.dart';
import 'state/learning_state.dart';
import 'team_details_screen.dart';
import 'models/team.dart';
import 'widgets/team_avatar.dart';

// ЕДИНЫЙ padding для контента (список и сетка одинаково!)
// Верхний отступ делаем отдельным слотом в Sliver, чтобы при сворачивании не было "прыжка" содержимого
const double _kHeaderSpacing = 12.0;
const EdgeInsets _kContentPadding = EdgeInsets.fromLTRB(16, 0, 16, 16);

class LearningScreen extends StatelessWidget {
  const LearningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<LearningCubit>(
      create: (_) => LearningCubit(),
      child: const _Body(),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  final AcademicContextService _academicContextService =
      AcademicContextService();
  RealtimeChannel? _teamsMembershipChannel;
  AcademicContext? _academicContext;
  bool _academicContextLoading = true;

  String get _currentGroupCode => _academicContext?.groupName ?? '';

  @override
  void initState() {
    super.initState();
    _loadAcademicContext();
    _subscribeToTeamsRealtime();
  }

  Future<void> _loadAcademicContext() async {
    final academicContext = await _academicContextService.load();
    if (!mounted) return;

    setState(() {
      _academicContext = academicContext;
      _academicContextLoading = false;
    });

    context.read<LearningCubit>().load(academicContext.groupName ?? '');
  }

  void _subscribeToTeamsRealtime() {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) return;

    _teamsMembershipChannel?.unsubscribe();

    _teamsMembershipChannel = client.channel('public:team_members:$uid')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'team_members',
        callback: (payload) {
          final row = payload.newRecord;
          if (row['user_id'] == uid) {
            context.read<LearningCubit>().load(_currentGroupCode);
          }
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'team_members',
        callback: (payload) {
          final row = payload.oldRecord;
          if (row['user_id'] == uid) {
            context.read<LearningCubit>().load(_currentGroupCode);
          }
        },
      )
      ..subscribe();
  }

  @override
  void dispose() {
    _teamsMembershipChannel?.unsubscribe();
    _teamsMembershipChannel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headerHeight =
        (MediaQuery.paddingOf(context).top + 86.0).clamp(128.0, 150.0);

    return BlocBuilder<LearningCubit, LearningState>(
      builder: (context, state) {
        return Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: headerHeight,
                child: _LandingHeader(
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _AcademicContextInfoButton(
                        contextData: _academicContext,
                        loading: _academicContextLoading,
                      ),
                      IconButton(
                        tooltip: state.viewMode == ViewMode.grid
                            ? 'Список'
                            : 'Плитка',
                        icon: Icon(
                          state.viewMode == ViewMode.grid
                              ? Icons.view_list
                              : Icons.grid_view_rounded,
                          color: Colors.black87,
                        ),
                        onPressed: () =>
                            context.read<LearningCubit>().toggleViewMode(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: _kHeaderSpacing),
              Expanded(
                child: Builder(
                  builder: (_) {
                    if (state.loading) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final cubit = context.read<LearningCubit>();
                    final groupChat = cubit.groupSpaceTeam;
                    final items = cubit.subjectTeams;
                    final groupName =
                        (_academicContext?.groupName ?? '').trim().isNotEmpty
                            ? _academicContext!.groupName!.trim()
                            : (groupChat?.groupCode.trim().isNotEmpty == true
                                ? groupChat!.groupCode.trim()
                                : 'Группа');

                    if (groupChat == null && items.isEmpty) {
                      return const _EmptyTeams();
                    }

                    if (state.viewMode == ViewMode.grid) {
                      return GridView.builder(
                        padding: _kContentPadding,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount:
                              MediaQuery.sizeOf(context).width >= 700 ? 3 : 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.6,
                        ),
                        itemCount: items.length + (groupChat != null ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (groupChat != null && i == 0) {
                            return _GroupChatCard(
                              team: groupChat,
                              groupName: groupName,
                            );
                          }
                          final idx = groupChat != null ? i - 1 : i;
                          return _TeamGridCard(items[idx]);
                        },
                      );
                    }

                    return ListView.separated(
                      padding: _kContentPadding,
                      itemCount: items.length + (groupChat != null ? 1 : 0),
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) {
                        if (groupChat != null && i == 0) {
                          return _GroupChatCard(
                            key: const ValueKey('learning-group-chat-card'),
                            team: groupChat,
                            groupName: groupName,
                          );
                        }
                        final idx = groupChat != null ? i - 1 : i;
                        return _TeamTile(items[idx]);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Permanent academic group chat entry (Stage 13.9) — not a subject card.
class _GroupChatCard extends StatelessWidget {
  const _GroupChatCard({
    super.key,
    required this.team,
    required this.groupName,
  });

  final Team team;
  final String groupName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: const ValueKey('open-learning-group-chat'),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TeamDetailsScreen(
            team: team.copyWith(
              name: groupName,
              icon: team.icon.isNotEmpty ? team.icon : 'groups',
            ),
            initialTabIndex: 1,
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.28),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            TeamAvatar(
              icon: team.icon.isNotEmpty ? team.icon : 'groups',
              name: 'Чат группы',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Чат группы',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$groupName · общий чат',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
            if (team.unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${team.unread}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TeamTile extends StatelessWidget {
  final Team team;
  const _TeamTile(this.team);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TeamDetailsScreen(team: team)),
      ),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            TeamAvatar(icon: team.icon, name: team.name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    team.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    team.teacher,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
            if (team.unread > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [theme.colorScheme.primary, Colors.black],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Text(
                  '${team.unread}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TeamGridCard extends StatelessWidget {
  final Team team;
  const _TeamGridCard(this.team);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 170;
        final avatarSize = compact ? 32.0 : 36.0;

        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => TeamDetailsScreen(team: team)),
          ),
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 14,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            padding: EdgeInsets.all(compact ? 9 : 11),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        TeamAvatar(
                          icon: team.icon,
                          name: team.name,
                          size: avatarSize,
                        ),
                        const Spacer(),
                      ],
                    ),
                    SizedBox(height: compact ? 6 : 8),
                    Text(
                      team.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                        height: 1.08,
                        fontSize: compact ? 13 : 14,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      team.teacher.trim().isEmpty
                          ? 'Преподаватель не указан'
                          : team.teacher,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black.withValues(alpha: 0.58),
                        height: 1.1,
                        fontSize: compact ? 11 : 12,
                      ),
                    ),
                  ],
                ),
                if (team.unread > 0)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _UnreadBadge(count: team.unread),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.colorScheme.primary, Colors.black],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _LandingHeader extends StatelessWidget {
  final Widget? trailing;
  const _LandingHeader({this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).height < 760;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                theme.colorScheme.primary.withOpacity(0.06),
                theme.colorScheme.primary.withOpacity(0.12),
              ],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                  diameter: 140,
                  color: theme.colorScheme.primary.withOpacity(0.10),
                ),
              ),
              Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                  diameter: 160,
                  color: Colors.white.withOpacity(0.55),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          bottom: false,
          child: SizedBox.expand(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 6),
              child: Align(
                alignment: Alignment(-1, compact ? 0.08 : 0.18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(compact ? 10 : 12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.10),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: Colors.white.withOpacity(0.85),
                            blurRadius: 8,
                            offset: const Offset(-2, -2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.groups_rounded,
                        color: theme.colorScheme.primary,
                        size: compact ? 26 : 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Команды',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: compact ? 30 : null,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                              height: 1.05,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withOpacity(0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: compact ? 2 : 4),
                          Text(
                            'Чат и задания',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: (compact
                                    ? theme.textTheme.bodySmall
                                    : theme.textTheme.bodyMedium)
                                ?.copyWith(
                              color: Colors.black.withOpacity(0.64),
                              height: 1.12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter;
  final Color color;
  const _GlowCircle({required this.diameter, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _AcademicContextInfoButton extends StatelessWidget {
  final AcademicContext? contextData;
  final bool loading;

  const _AcademicContextInfoButton({
    required this.contextData,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Учебный контекст',
      icon: const Icon(Icons.info_outline_rounded, color: Colors.black87),
      onPressed: () => _showAcademicContextSheet(context),
    );
  }

  void _showAcademicContextSheet(BuildContext context) {
    final groupText = loading
        ? 'Загрузка...'
        : (contextData?.groupName?.isNotEmpty == true
            ? contextData!.groupName!
            : 'Учебный контекст не найден');
    final semesterText = loading
        ? '...'
        : (contextData?.currentSemesterNumber?.toString() ?? 'не определён');
    final recordBookText = loading
        ? '...'
        : (contextData?.recordBookNumber?.isNotEmpty == true
            ? contextData!.recordBookNumber!
            : 'не указан');
    final warning = contextData?.loadWarning;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.school_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Моя учебная группа',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.black,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Команды — чаты по предметам вашей учебной группы: обсуждения, файлы и задания в одном месте.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.black.withOpacity(0.68),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                _AcademicContextLine(label: 'Группа', value: groupText),
                const SizedBox(height: 8),
                _AcademicContextLine(label: 'Семестр', value: semesterText),
                const SizedBox(height: 8),
                _AcademicContextLine(
                  label: '№ зачётки',
                  value: recordBookText,
                ),
                if (warning != null && warning.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    warning,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AcademicContextLine extends StatelessWidget {
  final String label;
  final String value;

  const _AcademicContextLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(
            '$label:',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.black.withOpacity(0.55),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.black,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyTeams extends StatelessWidget {
  const _EmptyTeams();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.groups_outlined,
                  size: 42, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              'Пока нет команд для вашей группы',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Команды появятся здесь, когда они будут доступны вашей группе',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7)),
            ),
          ],
        ),
      ),
    );
  }
}
