import 'dart:async';
import 'package:flutter/material.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
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
  const _Entry(this.team, this.chatId);
  final Team team;
  final String chatId;
}

class _CachedTeamChatDirectoryState extends State<CachedTeamChatDirectory> {
  CapabilityPermit? _permit;
  List<_Entry>? _entries;
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
      _permit = null;
      _revision++;
      unawaited(_load());
    }
  }

  void _changed() {
    if (!mounted || _allowed) return;
    _revision++;
    setState(() {
      _entries = null;
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
      final rows = await store.readSummaries(caps);
      if (!current()) return;
      if (rows == null || rows.length > 200) {
        setState(() {
          _permit = permit;
          _entries = null;
        });
        return;
      }
      final seen = <String>{};
      final result = <_Entry>[];
      for (final row in rows) {
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
        if (widget.subjectsOnly && kind != 'subject') continue;
        final teamId = tm['id'] as String;
        if (!seen.add(teamId)) continue;
        final saved = await store.read(id, caps);
        if (!current()) return;
        if (saved == null) continue;
        result.add(_Entry(
            Team(
                id: teamId,
                name: tm['name'] as String,
                teacher: tm['teacher'] as String,
                groupCode: tm['groupCode'] as String,
                icon: tm['icon'] as String,
                kind: kind as String),
            id));
      }
      if (current())
        setState(() {
          _permit = permit;
          _entries = result;
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
    final saved = await store.read(entry.chatId, caps);
    if (!mounted ||
        !identical(store, widget.store) ||
        !identical(caps, widget.capabilities) ||
        revision != _revision ||
        subjectsOnly != widget.subjectsOnly ||
        !(_entries?.any((item) => identical(item, entry)) ?? false) ||
        !_allowed ||
        !caps.permits(permit, SessionCapability.cachedRead)) return;
    if (saved == null) {
      setState(() => _entries =
          _entries?.where((item) => !identical(item, entry)).toList());
      return;
    }
    final nav = Navigator.of(context);
    final route = MaterialPageRoute<void>(
        builder: (_) => TeamDetailsScreen(
            team: entry.team,
            initialTabIndex: 1,
            cachedStore: store,
            cachedCapabilities: caps,
            cachedChatId: entry.chatId));
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed)
      return const Center(child: Text('Сохранённые данные недоступны.'));
    final entries = _entries;
    if (entries == null)
      return const Center(child: Text('Сохранённые чаты пока недоступны.'));
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        children: [
          Text(
              widget.subjectsOnly
                  ? 'Сохранённые чаты предметов'
                  : 'Сохранённые чаты команд',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(widget.subjectsOnly
              ? 'Здесь только ранее сохранённые чаты. Материалы без сети могут быть недоступны.'
              : 'Здесь только чаты, сохранённые на этом устройстве.'),
          const SizedBox(height: 16),
          if (entries.isEmpty)
            const Text('Сохранённых чатов пока нет.')
          else
            for (final entry in entries)
              Card(
                  child: ListTile(
                      leading: Icon(entry.team.kind == 'group_space'
                          ? Icons.groups_outlined
                          : Icons.menu_book_outlined),
                      title: Text(entry.team.name),
                      subtitle: Text(entry.team.kind == 'group_space'
                          ? 'Чат группы'
                          : 'Чат предмета'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => unawaited(_open(entry)))),
        ]),
    );
  }
}
