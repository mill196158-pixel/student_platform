// =============================
// FILE: lib/src/ui/learning/team_details_screen.dart
// =============================

// для мягких свечений
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';

import 'models/team.dart';
import 'state/team_cubit.dart';
import 'tabs/assignments_tab.dart';
import 'tabs/chat_tab.dart';
import 'tabs/chat/team/team_chat_notice.dart';
import 'tabs/files_tab.dart';
import 'tabs/assignments/view_mode.dart';
import 'widgets/team_avatar.dart';

class TeamDetailsScreen extends StatelessWidget {
  final Team team;
  final int initialTabIndex;

  /// Scroll/highlight this chat message after opening the chat tab (deeplink).
  final String? highlightMessageId;

  /// Completed-semester academic chats: history/files readable, no composer.
  final bool readOnly;
  const TeamDetailsScreen({
    super.key,
    required this.team,
    this.initialTabIndex = 1,
    this.highlightMessageId,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider<TeamCubit>(
      create: (_) {
        final c = TeamCubit(team, authScope: AuthSessionScopeHost.maybeRead(context));
        c.init();
        return c;
      },
      child: _Body(
        initialTabIndex: initialTabIndex,
        readOnly: readOnly,
        highlightMessageId: highlightMessageId,
      ),
    );
  }
}

class _Body extends StatefulWidget {
  final int initialTabIndex;
  final bool readOnly;
  final String? highlightMessageId;
  const _Body({
    super.key,
    this.initialTabIndex = 1,
    this.readOnly = false,
    this.highlightMessageId,
  });

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _selecting = false;

  // Compact header: more room for chat / assignments below.
  static const double _kHeaderContentHeight = 64.0;
  static const double _kTabsTopGap = 6.0;

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
    // Когда открыта клавиатура (набор сообщения в чате), скрываем крупную
    // шапку с названием команды, чтобы освободить место композеру и не
    // получить overflow при добавлении вложений. Полоска вкладок остаётся.
    final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    final showHeader = !_selecting && !keyboardOpen;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // В режиме выделения шапку заменяет TopSelectionBar внутри ChatTab.
          if (!_selecting) ...[
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: showHeader
                  ? SizedBox(
                      height: MediaQuery.of(context).padding.top +
                          _kHeaderContentHeight,
                      child: _TeamHeader(
                        team: team,
                        leading:
                            const _RoundBackButton(), // назад слева в шапке
                        trailing: showAssignmentsActions
                            ? const AssignmentsViewModeButton()
                            : _TeamChatHeaderActions(team: team),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
            const SizedBox(height: _kTabsTopGap),
            // Сильно сжатый сегмент-контрол для вкладок (уменьшен на ~60%)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8), // меньше радиус
                  boxShadow: const [],
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
                        boxShadow: const [],
                      ),
                      indicatorSize: TabBarIndicatorSize.tab,
                      labelColor: Theme.of(context).colorScheme.onPrimary,
                      unselectedLabelColor:
                          Theme.of(context).colorScheme.onSurfaceVariant,
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
                  ChatTab(
                    onSelectingChanged: (v) => setState(() => _selecting = v),
                    readOnly: widget.readOnly,
                    highlightMessageId: widget.highlightMessageId,
                  ),
                  FilesTab(isActive: _tabController.index == 2),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Group chat: direct Info + Members. Subject chat: modern schedule-style ⋯.
class _TeamChatHeaderActions extends StatelessWidget {
  const _TeamChatHeaderActions({required this.team});

  final Team team;

  void _openInfo(BuildContext context) {
    showTeamChatNoticeSheet(context: context, teamId: team.id);
  }

  void _openMembers(BuildContext context) {
    final canExport = context.read<TeamCubit>().state.isStarosta;
    showTeamMembersSheet(
      context: context,
      teamId: team.id,
      teamTitle: team.isGroupSpaceChat
          ? (team.groupCode.trim().isNotEmpty ? team.groupCode : team.name)
          : team.name,
      groupLabel: team.groupCode.trim().isEmpty ? null : team.groupCode.trim(),
      canExportRoster: canExport,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    if (team.isGroupSpaceChat) {
      // «В чате группы просто информация» + участники отдельными иконками.
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeaderRoundButton(
            tooltip: 'Информация',
            icon: Icons.info_outline_rounded,
            onPressed: () => _openInfo(context),
          ),
          const SizedBox(width: 6),
          _HeaderRoundButton(
            tooltip: 'Участники',
            icon: Icons.groups_rounded,
            onPressed: () => _openMembers(context),
          ),
        ],
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Ещё',
      onSelected: (value) {
        if (value == 'notice') _openInfo(context);
        if (value == 'members') _openMembers(context);
      },
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      constraints: const BoxConstraints(minWidth: 244),
      itemBuilder: (ctx) => const [
        PopupMenuItem(
          value: 'notice',
          height: 58,
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: _TeamMenuItem(
            icon: Icons.info_outline_rounded,
            title: 'Информация',
            subtitle: 'Общая доска для группы',
          ),
        ),
        PopupMenuDivider(height: 8),
        PopupMenuItem(
          value: 'members',
          height: 58,
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: _TeamMenuItem(
            icon: Icons.groups_rounded,
            title: 'Участники',
            subtitle: 'Список по алфавиту с номерами',
          ),
        ),
      ],
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primary.withValues(alpha: 0.10)),
          boxShadow: const [],
        ),
        child: Icon(Icons.more_horiz_rounded, color: primary, size: 24),
      ),
    );
  }
}

class _HeaderRoundButton extends StatelessWidget {
  const _HeaderRoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primary.withValues(alpha: 0.10)),
              boxShadow: const [],
            ),
            child: Icon(icon, color: primary, size: 22),
          ),
        ),
      ),
    );
  }
}

class _TeamMenuItem extends StatelessWidget {
  const _TeamMenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ],
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
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: const [],
      ),
      child: IconButton(
        tooltip: 'Назад',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
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
    const titleSize = 15.0;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Flat header surface shared with the workspace.
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
          ),
        ),
        // Контент — плотно под статус-баром / Dynamic Island.
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 8, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: 8),
                  ],
                  TeamAvatar(icon: team.icon, name: team.name, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          team.isGroupSpaceChat
                              ? (team.groupCode.trim().isNotEmpty
                                  ? team.groupCode.trim()
                                  : team.name)
                              : team.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontSize: titleSize,
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.onSurface,
                            height: 1.05,
                          ),
                        ),
                        if (team.isGroupSpaceChat) ...[
                          const SizedBox(height: 1),
                          Text(
                            'Общий чат группы',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.1,
                              fontSize: 11,
                            ),
                          ),
                        ] else if (team.teacher.trim().isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Text(
                            team.teacher,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.1,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 4),
                    IconTheme(
                      data: const IconThemeData(size: 22),
                      child: trailing!,
                    ),
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
