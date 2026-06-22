// =============================
// FILE: lib/src/ui/learning/team_details_screen.dart
// =============================

import 'dart:ui' as ui; // для мягких свечений
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:characters/characters.dart';

import 'models/team.dart';
import 'state/team_cubit.dart';
import 'tabs/assignments_tab.dart';
import 'tabs/chat_tab.dart';
import 'tabs/files_tab.dart';
import 'tabs/assignments/view_mode.dart';

class TeamDetailsScreen extends StatelessWidget {
  final Team team;
  final int initialTabIndex;
  const TeamDetailsScreen(
      {super.key, required this.team, this.initialTabIndex = 1});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<TeamCubit>(
      create: (_) {
        final c = TeamCubit(team);
        c.init();
        return c;
      },
      child: _Body(initialTabIndex: initialTabIndex),
    );
  }
}

class _Body extends StatefulWidget {
  final int initialTabIndex;
  const _Body({super.key, this.initialTabIndex = 1});

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _selecting = false;

  static const double _kHeaderHeight = 128.0;
  static const double _kTabsTopGap = 0.0; // максимально прижать к шапке

  @override
  void initState() {
    super.initState();
    final idx = widget.initialTabIndex.clamp(0, 2);
    _tabController = TabController(length: 3, vsync: this, initialIndex: idx);
    _tabController.addListener(() {
      setState(() {}); // чтобы trailing на «Заданиях» обновлялся
      FocusScope.of(context).unfocus(); // закрыть клавиатуру при смене вкладки
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TeamCubit>();
    final team = cubit.state.team;
    final theme = Theme.of(context);

    final showAssignmentsActions = _tabController.index == 0;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // В режиме выделения сообщений шапку полностью заменяет floating selection bar внутри чата.
          if (!_selecting) ...[
            SizedBox(
              height: _kHeaderHeight,
              child: _TeamHeader(
                team: team,
                leading: const _RoundBackButton(), // назад слева в шапке
                trailing: showAssignmentsActions
                    ? const AssignmentsViewModeButton()
                    : null,
              ),
            ),
            const SizedBox(height: _kTabsTopGap),
            // Сильно сжатый сегмент-контрол для вкладок (уменьшен на ~60%)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8), // меньше радиус
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 8, // меньше тень
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(1), // было 6 → 1 (еще компактнее)
                child: Theme(
                  data: theme.copyWith(
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    dividerColor: Colors.transparent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity:
                        const VisualDensity(horizontal: -4, vertical: -4),
                  ),
                  child: SizedBox(
                    height: 30,
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: false,
                      indicatorPadding: EdgeInsets.zero,
                      labelPadding: EdgeInsets.zero,
                      indicator: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withOpacity(0.14),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      indicatorSize: TabBarIndicatorSize.tab,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.black.withOpacity(0.64),
                      tabs: const [
                        _MiniTab('Задания'),
                        _MiniTab('Чат'),
                        _MiniTab('Файлы'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],

          // Контент вкладок максимально близко к табам
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true, // убрать любой верхний safe area у контента
              child: TabBarView(
                controller: _tabController,
                children: [
                  AssignmentsTab(team: team),
                  // Чат сообщает о режиме выделения, шапка исчезает — логика сохранена
                  ChatTab(
                      onSelectingChanged: (v) =>
                          setState(() => _selecting = v)),
                  const FilesTab(), // без отступов сверху — прижато к табам
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AssignmentsViewModeButton extends StatelessWidget {
  const AssignmentsViewModeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AssignmentsViewMode.grid,
      builder: (_, asGrid, __) => IconButton(
        tooltip: asGrid ? 'Показать списком' : 'Показать сеткой',
        icon: Icon(asGrid ? Icons.view_list : Icons.grid_view_rounded),
        onPressed: () => AssignmentsViewMode.grid.value = !asGrid,
      ),
    );
  }
}

/// Круглая кнопка «Назад» в шапке
class _RoundBackButton extends StatelessWidget {
  const _RoundBackButton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: IconButton(
        tooltip: 'Назад',
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

/// Шапка как на LearningScreen, НО: название в 2 раза меньше базового headlineSmall.
class _TeamHeader extends StatelessWidget {
  final Team team;
  final Widget? leading;
  final Widget? trailing;
  const _TeamHeader({required this.team, this.leading, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.headlineSmall?.fontSize ?? 24.0;
    final titleSize = base / 2; // уменьшили в 2 раза

    return Stack(
      fit: StackFit.expand,
      children: [
        // Градиент фона
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
        // Мягкие свечения
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
        // Контент
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Align(
              alignment: const Alignment(-1, 0.26),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: 10),
                  ],
                  _TeamAvatarSmall(icon: team.icon, name: team.name),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          team.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontSize: titleSize,
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
                          team.teacher,
                          maxLines: 1,
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

class _TeamAvatarSmall extends StatelessWidget {
  final String icon;
  final String name;
  const _TeamAvatarSmall({required this.icon, required this.name});

  bool get _isUrl => icon.startsWith('http://') || icon.startsWith('https://');

  @override
  Widget build(BuildContext context) {
    final initials =
        (name.isNotEmpty ? name.trim().characters.first.toUpperCase() : 'T');
    final colorSeed = initials.codeUnitAt(0);
    final hue = (colorSeed % 360).toDouble();
    final bgColor = HSLColor.fromAHSL(1, hue, 0.55, 0.48).toColor();

    return Container(
      height: 44,
      width: 44,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(11),
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
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.white,
                fontSize: 19,
              ),
            )
          : null,
    );
  }
}

// Компактные табы с фиксированной высотой
class _MiniTab extends StatelessWidget {
  final String text;
  const _MiniTab(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    // Если у Tab есть параметр height (Flutter >= 3.7), он будет использован.
    // Для совместимости формируем через child с фиксированной высотой.
    return Tab(
      child: SizedBox(
        height: 28,
        child: Center(child: Text(text)),
      ),
    );
  }
}
