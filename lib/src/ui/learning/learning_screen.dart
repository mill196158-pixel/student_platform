// =============================
// FILE: lib/src/ui/learning/learning_screen.dart
// =============================

import 'dart:ui' as ui; // для мягких свечений
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:student_platform/src/data/academic_context_service.dart';
import 'state/learning_cubit.dart';
import 'state/learning_state.dart';
import 'team_details_screen.dart';
import 'models/team.dart';
import 'manage/manage_teams_screen.dart';

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
    return BlocBuilder<LearningCubit, LearningState>(
      builder: (context, state) {
        return Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 128,
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
                        icon: Icon(state.viewMode == ViewMode.grid
                            ? Icons.view_list
                            : Icons.grid_view_rounded),
                        onPressed: () =>
                            context.read<LearningCubit>().toggleViewMode(),
                      ),
                      IconButton(
                        tooltip: 'Управление командами',
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () {
                          final cubit = context.read<LearningCubit>();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => BlocProvider.value(
                                value: cubit,
                                child: ManageTeamsScreen(
                                  groupCode: _currentGroupCode,
                                ),
                              ),
                            ),
                          );
                        },
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

                    final items = context.read<LearningCubit>().visibleTeams;

                    if (items.isEmpty) {
                      return _EmptyTeams(groupCode: _currentGroupCode);
                    }

                    if (state.viewMode == ViewMode.grid) {
                      // СЕТКА — padding внутри самого GridView
                      return GridView.builder(
                        padding: _kContentPadding,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.6,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _TeamGridCard(items[i]),
                      );
                    }

                    // СПИСОК — тот же padding
                    return ListView.separated(
                      padding: _kContentPadding,
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _TeamTile(items[i]),
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
            _TeamAvatar(icon: team.icon, name: team.name),
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
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withOpacity(0.62),
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
              color: Colors.black.withOpacity(0.06),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TeamAvatar(icon: team.icon, name: team.name, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    team.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                      height: 1.12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              team.teacher,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.black.withOpacity(0.62)),
            ),
            const Spacer(),
            if (team.unread > 0)
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
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
              ),
          ],
        ),
      ),
    );
  }
}

class _TeamAvatar extends StatelessWidget {
  final String icon;
  final String name;
  final double size;
  const _TeamAvatar({required this.icon, required this.name, this.size = 44});

  bool get _isUrl => icon.startsWith('http://') || icon.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final initials =
        (name.isNotEmpty ? name.trim().characters.first.toUpperCase() : 'T');
    final colorSeed = initials.codeUnitAt(0);
    final hue = (colorSeed % 360).toDouble();
    final bgColor = HSLColor.fromAHSL(1, hue, 0.55, 0.48).toColor();

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(size / 4),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
        image: _isUrl
            ? DecorationImage(
                image: CachedNetworkImageProvider(icon), fit: BoxFit.cover)
            : null,
        gradient: _isUrl
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [bgColor.withOpacity(0.95), bgColor],
              ),
      ),
      alignment: Alignment.center,
      child: !_isUrl
          ? Text(
              initials,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.white,
                fontSize: size * 0.44,
              ),
            )
          : null,
    );
  }
}

class _LandingHeader extends StatelessWidget {
  final Widget? trailing;
  const _LandingHeader({this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Align(
                alignment: const Alignment(-1, 0.26),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
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
                        size: 28,
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
                          const SizedBox(height: 6),
                          Text(
                            'Чат и задания',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.black.withOpacity(0.64),
                              height: 1.25,
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
      icon: const Icon(Icons.info_outline_rounded),
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
    final warning = contextData?.loadWarning;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
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
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _AcademicContextLine(label: 'Группа', value: groupText),
                const SizedBox(height: 8),
                _AcademicContextLine(label: 'Семестр', value: semesterText),
                const SizedBox(height: 8),
                const _AcademicContextLine(
                  label: 'Источник',
                  value: 'student_enrollments / group_term_semesters',
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
              color: theme.colorScheme.onSurface.withOpacity(0.62),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyTeams extends StatelessWidget {
  final String groupCode;

  const _EmptyTeams({required this.groupCode});

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
              'Добавьте или присоединитесь к команде, чтобы начать работу',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7)),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                final cubit = context.read<LearningCubit>();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BlocProvider.value(
                      value: cubit,
                      child: ManageTeamsScreen(
                        groupCode: groupCode,
                      ),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Управление командами'),
            ),
          ],
        ),
      ),
    );
  }
}
