import 'dart:async';
import 'package:flutter/material.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/scoped_team_catalog.dart';
import 'package:student_platform/src/ui/learning/learning_screen.dart'
    show StudentTeamTile;
import 'package:student_platform/src/ui/shared/student_section_headers.dart'
    show StudentLearningHeader;
import 'package:student_platform/src/ui/learning/team_details_screen.dart';

/// Restricted QA adapter: these are saved chat snapshots, not a materials or
/// subject catalogue. No legacy cache, media URLs, or network calls are used.
class CachedTeamChatDirectory extends StatefulWidget {
  const CachedTeamChatDirectory(
      {super.key,
      required this.store,
      required this.capabilities,
      required this.subjectsOnly});
  final ProjectChatServerCache store;
  final SessionCapabilities capabilities;
  final bool subjectsOnly;
  @override
  State<CachedTeamChatDirectory> createState() =>
      _CachedTeamChatDirectoryState();
}

class _Entry {
  const _Entry(this.team, this.chatId, this.historyAvailable);
  final Team team;
  final String? chatId;
  final bool historyAvailable;
}

class _CachedTeamChatDirectoryState extends State<CachedTeamChatDirectory> {
  CapabilityPermit? _permit;
  List<_Entry>? _entries;
  DateTime? _catalogSavedAt;
  int _revision = 0;
  final Set<VoidCallback> _routeClosers = {};
  bool get _allowed =>
      _permit != null &&
      widget.capabilities.mode == SessionCapabilityMode.cacheOnly &&
      widget.capabilities.permits(_permit!, SessionCapability.cachedRead);

  @override
  void initState() {
    super.initState();
    widget.capabilities.addListener(_changed);
    ScopedTeamCatalogStore.changes.addListener(_catalogChanged);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant CachedTeamChatDirectory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store) ||
        !identical(oldWidget.capabilities, widget.capabilities) ||
        oldWidget.subjectsOnly != widget.subjectsOnly) {
      for (final close in _routeClosers.toList()) {
        close();
      }
      oldWidget.capabilities.removeListener(_changed);
      widget.capabilities.addListener(_changed);
      _entries = null;
      _catalogSavedAt = null;
      _permit = null;
      _revision++;
      unawaited(_load());
    }
  }

  void _catalogChanged() {
    if (!mounted || widget.subjectsOnly || !_allowed) return;
    _revision++;
    setState(() {
      _entries = null;
      _catalogSavedAt = null;
    });
    unawaited(_load());
  }

  void _changed() {
    if (!mounted || _allowed) return;
    _revision++;
    setState(() {
      _entries = null;
      _catalogSavedAt = null;
      _permit = null;
    });
  }

  Future<void> _load() async {
    final caps = widget.capabilities, store = widget.store;
    final permit = caps.capture(SessionCapability.cachedRead);
    final revision = ++_revision;
    if (permit == null || caps.mode != SessionCapabilityMode.cacheOnly) return;
    _permit = permit;
    bool current() =>
        mounted &&
        identical(caps, widget.capabilities) &&
        identical(store, widget.store) &&
        revision == _revision &&
        caps.mode == SessionCapabilityMode.cacheOnly &&
        caps.permits(permit, SessionCapability.cachedRead);
    try {
      TeamCatalogSnapshot? catalog;
      if (!widget.subjectsOnly) {
        ScopedTeamCatalogStore? catalogStore;
        try {
          catalogStore = ScopedTeamCatalogStore(
              db: store.db,
              scope: store.scope,
              currentBinding: store.currentBinding,
              project: store.project);
        } catch (_) {
          // A mock without database support may still supply scoped summaries.
        }
        if (catalogStore != null) {
          final denied = await catalogStore.isDenied(caps);
          if (!current()) return;
          // Never fall back to summaries if denial exists or cannot be read.
          if (denied != false) {
            setState(() {
              _permit = permit;
              _entries = null;
              _catalogSavedAt = null;
            });
            return;
          }
          catalog = await catalogStore.read(caps);
        }
      }
      if (!current()) return;
      final rows = await store.readSummaries(caps);
      if (!current()) return;
      if (catalog == null && (rows == null || rows.length > 200)) {
        setState(() {
          _permit = permit;
          _entries = null;
          _catalogSavedAt = null;
        });
        return;
      }
      final summaries = <String, (String, Team)>{};
      final ambiguous = <String>{};
      for (final row in rows ?? const <Map<String, dynamic>>[]) {
        final tm = row['team'], id = row['chatId'];
        if (row['isDm'] != false ||
            tm is! Map ||
            id is! String ||
            id.trim().isEmpty ||
            tm['id'] is! String ||
            (tm['id'] as String).trim().isEmpty ||
            tm['name'] is! String ||
            tm['teacher'] is! String ||
            tm['groupCode'] is! String ||
            tm['icon'] is! String) continue;
        final kind = tm['kind'];
        if (kind != 'subject' && kind != 'group_space') continue;
        final teamId = tm['id'] as String;
        if (summaries.containsKey(teamId)) {
          summaries.remove(teamId);
          ambiguous.add(teamId);
          continue;
        }
        if (ambiguous.contains(teamId)) continue;
        summaries[teamId] = (
          id,
          Team(
              id: teamId,
              name: tm['name'] as String,
              teacher: tm['teacher'] as String,
              groupCode: tm['groupCode'] as String,
              icon: tm['icon'] as String,
              kind: kind as String)
        );
      }
      final result = <_Entry>[];
      final teams =
          catalog?.teams ?? summaries.values.map((value) => value.$2).toList();
      for (final team in teams) {
        if (widget.subjectsOnly && team.kind != 'subject') continue;
        final chatId = summaries[team.id]?.$1;
        final saved = chatId == null ? null : await store.read(chatId, caps);
        if (!current()) return;
        result.add(_Entry(team, chatId, saved != null));
      }
      if (!widget.subjectsOnly) {
        // Match the online screen: the group chat precedes subject teams,
        // while preserving the saved relative order within each type.
        final groups =
            result.where((entry) => entry.team.kind == 'group_space').toList();
        final subjects =
            result.where((entry) => entry.team.kind != 'group_space').toList();
        result
          ..clear()
          ..addAll(groups)
          ..addAll(subjects);
      }
      if (current())
        setState(() {
          _permit = permit;
          _entries = result;
          _catalogSavedAt = catalog?.savedAt;
        });
    } catch (_) {
      if (current())
        setState(() {
          _permit = permit;
          _entries = null;
        });
    }
  }

  Future<void> _open(_Entry entry) async {
    if (!_allowed) return;
    final caps = widget.capabilities, permit = _permit!;
    final store = widget.store;
    final revision = _revision, subjectsOnly = widget.subjectsOnly;
    final chatId = entry.chatId;
    final saved = chatId == null ? null : await store.read(chatId, caps);
    if (!mounted ||
        !identical(store, widget.store) ||
        !identical(caps, widget.capabilities) ||
        revision != _revision ||
        subjectsOnly != widget.subjectsOnly ||
        !(_entries?.any((item) => identical(item, entry)) ?? false) ||
        !_allowed ||
        !caps.permits(permit, SessionCapability.cachedRead)) return;
    if (saved == null) {
      setState(() => _entries = _entries
          ?.map((item) => identical(item, entry)
              ? _Entry(item.team, item.chatId, false)
              : item)
          .toList());
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('История этого чата не сохранена на устройстве.')));
      return;
    }
    final nav = Navigator.of(context);
    final route = MaterialPageRoute<void>(
        builder: (_) => TeamDetailsScreen(
            team: entry.team,
            initialTabIndex: 1,
            cachedStore: store,
            cachedCapabilities: caps,
            cachedChatId: chatId!));
    void close() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (nav.mounted && route.isActive) nav.removeRoute(route);
      });
    }

    void check() {
      if (caps.mode == SessionCapabilityMode.cacheOnly &&
          caps.permits(permit, SessionCapability.cachedRead)) return;
      close();
    }

    _routeClosers.add(close);
    caps.addListener(check);
    unawaited(nav.push(route).whenComplete(() {
      caps.removeListener(check);
      _routeClosers.remove(close);
    }));
    check();
  }

  @override
  void dispose() {
    _revision++;
    for (final close in _routeClosers.toList()) {
      close();
    }
    widget.capabilities.removeListener(_changed);
    ScopedTeamCatalogStore.changes.removeListener(_catalogChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed)
      return const Center(child: Text('Сохранённые данные недоступны.'));
    final entries = _entries;
    if (entries == null)
      return const Center(child: Text('Сохранённые чаты пока недоступны.'));
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.subjectsOnly)
          SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(children: [
                  Icon(Icons.lightbulb_outline_rounded,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  Text('База',
                      style: Theme.of(context).textTheme.headlineSmall),
                ]),
              ))
        else
          SizedBox(
            height:
                (MediaQuery.paddingOf(context).top + 86.0).clamp(128.0, 150.0),
            child: const StudentLearningHeader(),
          ),
        Expanded(
            child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (_catalogSavedAt != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                      'Сохранено ${_catalogSavedAt!.toLocal().day.toString().padLeft(2, '0')}.${_catalogSavedAt!.toLocal().month.toString().padLeft(2, '0')}.${_catalogSavedAt!.toLocal().year}. Данные могут устареть.',
                      style: Theme.of(context).textTheme.bodySmall)),
            if (entries.isEmpty)
              const Text(
                  'Нет сохранённых данных. Подключитесь к сети, чтобы обновить список.')
            else
              for (final entry in entries) ...[
                StudentTeamTile(entry.team,
                    onTap: () => unawaited(_open(entry))),
                if (entry.team.kind == 'unknown')
                  Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                      child: Text('Тип команды не подтверждён',
                          style: Theme.of(context).textTheme.bodySmall)),
                if (!entry.historyAvailable)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                    child: Text('История не сохранена на устройстве',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ),
                const SizedBox(height: 12),
              ],
          ],
        )),
      ]),
    );
  }
}
