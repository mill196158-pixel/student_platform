// =============================
// FILE: lib/src/ui/learning/team_details_screen.dart
// =============================

// для мягких свечений
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/chats/guarded_push_dm_read_only.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_message_bubble.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_composer.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

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
  final ProjectChatServerCache? cachedStore;
  final SessionCapabilities? cachedCapabilities;
  final String? cachedChatId;
  /// Experimental push-only read path; never starts TeamCubit.
  final SupabaseClient? guardedPushClient;
  final String? guardedPushUserId;
  final String? guardedPushChatId;
  final OnlineSideEffectBarrier? guardedPushBarrier;
  final bool Function()? guardedPushSessionIsCurrent;
  const TeamDetailsScreen({
    super.key,
    required this.team,
    this.initialTabIndex = 1,
    this.highlightMessageId,
    this.readOnly = false,
    this.cachedStore,
    this.cachedCapabilities,
    this.cachedChatId,
    this.guardedPushClient,
    this.guardedPushUserId,
    this.guardedPushChatId,
    this.guardedPushBarrier,
    this.guardedPushSessionIsCurrent,
  });

  @override
  Widget build(BuildContext context) {
    if (guardedPushClient != null || guardedPushUserId != null ||
        guardedPushChatId != null || guardedPushBarrier != null ||
        guardedPushSessionIsCurrent != null) {
      final client = guardedPushClient, user = guardedPushUserId,
          chat = guardedPushChatId, barrier = guardedPushBarrier,
          current = guardedPushSessionIsCurrent;
      if (client == null || user == null || user.isEmpty || chat == null ||
          chat.isEmpty || barrier == null || current == null || team.id.isEmpty) {
        return const SizedBox.shrink();
      }
      return GuardedPushDmReadOnly(
          key: ValueKey((client, user, team.id, chat, barrier, current)),
          client: client, userId: user, chatId: chat, barrier: barrier,
          isCurrent: current, title: 'Чат команды');
    }
    if (cachedStore != null ||
        cachedCapabilities != null ||
        cachedChatId != null) {
      final store = cachedStore,
          caps = cachedCapabilities,
          chatId = cachedChatId;
      if (store == null || caps == null || chatId == null || chatId.isEmpty) {
        return const Scaffold(
            body: Center(child: Text('Сохранённый чат недоступен.')));
      }
      return _CachedTeamDetails(
          team: team,
          chatId: chatId,
          store: store,
          capabilities: caps,
          initialTabIndex: initialTabIndex);
    }
    return BlocProvider<TeamCubit>(
      create: (_) {
        final c =
            TeamCubit(team, authScope: AuthSessionScopeHost.maybeRead(context));
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

/// Experimental cache-only route. It never constructs TeamCubit or its tabs,
/// which start subscriptions and network requests during initialization.
class _CachedTeamDetails extends StatefulWidget {
  const _CachedTeamDetails(
      {required this.team,
      required this.chatId,
      required this.store,
      required this.capabilities,
      required this.initialTabIndex});
  final Team team;
  final String chatId;
  final ProjectChatServerCache store;
  final SessionCapabilities capabilities;
  final int initialTabIndex;

  @override
  State<_CachedTeamDetails> createState() => _CachedTeamDetailsState();
}

class _CachedTeamDetailsState extends State<_CachedTeamDetails>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _scroll = ScrollController();
  final _search = ChatSearchController();
  final _keys = <String, GlobalKey>{};
  DmChatService? _filePermit;
  CapabilityPermit? _permit;
  Future<List<Message>?>? _messages;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
        length: 3,
        vsync: this,
        initialIndex: widget.initialTabIndex.clamp(0, 2));
    _bind();
  }

  void _bind() {
    _revision++;
    final caps = widget.capabilities;
    final permit = caps.capture(SessionCapability.cachedRead);
    if (caps.mode != SessionCapabilityMode.cacheOnly || permit == null) return;
    try {
      _filePermit = DmChatService.cachedOnly(
          peerId: '',
          initialChatId: widget.chatId,
          capabilities: caps,
          cacheReader: (_, __) async => throw const CachedChatUnavailable());
      _permit = permit;
      _messages = widget.store.read(widget.chatId, caps);
    } catch (_) {
      _filePermit = null;
      _permit = null;
    }
  }

  bool get _allowed =>
      _permit != null &&
      widget.capabilities.mode == SessionCapabilityMode.cacheOnly &&
      widget.capabilities.permits(_permit!, SessionCapability.cachedRead) &&
      (_filePermit?.canReadCached ?? false);

  @override
  void didUpdateWidget(covariant _CachedTeamDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId ||
        oldWidget.team.id != widget.team.id ||
        !identical(oldWidget.store, widget.store) ||
        !identical(oldWidget.capabilities, widget.capabilities)) {
      _filePermit?.dispose();
      _filePermit = null;
      _permit = null;
      _messages = null;
      _bind();
    }
  }

  @override
  void dispose() {
    _filePermit?.dispose();
    _tabs.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.capabilities,
      builder: (context, _) {
        if (!_allowed)
          return const Scaffold(
              body: Center(child: Text('Сохранённый чат недоступен.')));
        final colors = Theme.of(context).colorScheme;
        return Scaffold(
            body: Column(children: [
          SizedBox(
              height: MediaQuery.paddingOf(context).top + 64,
              child: _TeamHeader(
                  team: widget.team.copyWith(icon: ''),
                  leading: const _RoundBackButton(),
                  trailing: const SizedBox.shrink())),
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Container(
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.all(1),
                child: Theme(data: Theme.of(context).copyWith(
                    splashColor: Colors.transparent, highlightColor: Colors.transparent,
                    dividerColor: Colors.transparent, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: const VisualDensity(horizontal: -4, vertical: -4)),
                  child: SizedBox(height: 30, child: TabBar(
                  controller: _tabs,
                  tabs: const [
                    _MiniTab('Задания'),
                    _MiniTab('Чат'),
                    _MiniTab('Файлы')
                  ],
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: EdgeInsets.zero,
                  labelPadding: EdgeInsets.zero,
                  indicator: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(6)),
                  labelColor: colors.onPrimary,
                  unselectedLabelColor: colors.onSurfaceVariant))))),
          Expanded(
              child: TabBarView(controller: _tabs, children: [
            const Center(child: Text('Сохранённые задания недоступны.')),
            Column(children: [Expanded(child: FutureBuilder<List<Message>?>(
                key: ValueKey(_revision),
                future: _messages,
                builder: (context, snapshot) {
                  if (!_allowed) return const SizedBox.shrink();
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                        child: Text('Открываем сохранённые сообщения…'));
                  }
                  if (snapshot.hasError || snapshot.data == null) {
                    return const Center(
                        child: Text('Сохранённые сообщения недоступны.'));
                  }
                  final messages = snapshot.data!
                      .where((m) =>
                          (m.cardKind?.trim().isEmpty ?? true) &&
                          !ChatCardPreview.looksLikeCardJson(m.text) &&
                          m.type != MessageType.assignmentDraft &&
                          m.type != MessageType.assignmentPublished)
                      .toList();
                  if (messages.isEmpty)
                    return Center(
                        child: Text(snapshot.data!.isEmpty
                            ? 'Сообщений пока нет'
                            : 'Часть сообщений пока недоступна офлайн.'));
                  return ChatMessageList(
                      messages: messages,
                      controller: _scroll,
                      messageKeys: _keys,
                      search: _search,
                      currentUserId: _filePermit!.currentUserId,
                      forceHideAvatars: true,
                      noAvatarSpacing: true,
                      hideAuthorLine: true,
                      isDirectChat: false,
                      showEntryNewBadge: false,
                      selectingMessages: false,
                      selectedMessageIds: const <String>{},
                      onToggleSelect: null,
                      onReply: (_) {},
                      onLongPress: (_, __, ___, ____, _____, ______) {},
                      onReplyTap: (_) {},
                      onReact: (_, __) {},
                      localOnlyBubbleBuilder: (message) => CachedChatMessageBubble(
                          message: message, service: _filePermit!, showAuthor: true));
                })), const CachedChatComposer()]),
            const Center(child: Text('Сохранённый список файлов недоступен.')),
          ]))
        ]));
      });
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
