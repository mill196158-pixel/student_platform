import 'package:flutter/material.dart';

import '../../academic/students/students_repository.dart';

/// Searchable group/user selectors with human-readable labels.
/// IDs stay internal; never shown as the primary UI value.
class ContentAudienceSelectors extends StatefulWidget {
  const ContentAudienceSelectors({
    super.key,
    required this.studentsRepository,
    required this.audienceMode,
    required this.selectedGroupIds,
    required this.selectedUserIds,
    required this.enabled,
    required this.onChanged,
  });

  final StudentsRepository studentsRepository;
  final String audienceMode;
  final List<String> selectedGroupIds;
  final List<String> selectedUserIds;
  final bool enabled;
  final void Function({
    required List<String> groupIds,
    required List<String> userIds,
  })
  onChanged;

  @override
  State<ContentAudienceSelectors> createState() =>
      _ContentAudienceSelectorsState();
}

class _ContentAudienceSelectorsState extends State<ContentAudienceSelectors> {
  List<GroupItem> _groups = const [];
  final Map<String, StudentItem> _userLabels = {};
  bool _loading = true;
  String? _error;

  bool get _needGroups =>
      widget.audienceMode == 'groups' ||
      widget.audienceMode == 'groups_and_users';
  bool get _needUsers =>
      widget.audienceMode == 'users' ||
      widget.audienceMode == 'groups_and_users';

  @override
  void initState() {
    super.initState();
    _loadGroups();
    _hydrateUsers(widget.selectedUserIds);
  }

  @override
  void didUpdateWidget(covariant ContentAudienceSelectors oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedUserIds.join() != widget.selectedUserIds.join()) {
      _hydrateUsers(widget.selectedUserIds);
    }
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final groups = await widget.studentsRepository.listGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _hydrateUsers(List<String> ids) async {
    for (final id in ids) {
      if (_userLabels.containsKey(id)) continue;
      try {
        final found = await widget.studentsRepository.listStudents(query: id);
        for (final student in found) {
          if (student.id == id) {
            _userLabels[id] = student;
            break;
          }
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  String _groupLabel(String id) {
    for (final g in _groups) {
      if (g.id == id) return g.name;
    }
    return 'Группа';
  }

  String _userLabel(String id) {
    final s = _userLabels[id];
    if (s == null) return 'Студент';
    final name = '${s.surname} ${s.name}'.trim();
    if (name.isNotEmpty) return name;
    return s.login;
  }

  Future<void> _pickGroup() async {
    if (!widget.enabled || _groups.isEmpty) return;
    final selected = await showDialog<GroupItem>(
      context: context,
      builder: (context) => _SearchPickDialog<GroupItem>(
        title: 'Выбор группы',
        items: _groups,
        labelOf: (g) => '${g.name} (${g.membersCount})',
        filter: (g, q) => g.name.toLowerCase().contains(q),
      ),
    );
    if (selected == null) return;
    if (widget.selectedGroupIds.contains(selected.id)) return;
    widget.onChanged(
      groupIds: [...widget.selectedGroupIds, selected.id],
      userIds: widget.selectedUserIds,
    );
  }

  Future<void> _pickUser() async {
    if (!widget.enabled) return;
    final queryController = TextEditingController();
    List<StudentItem> results = const [];
    final selected = await showDialog<StudentItem>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: const Text('Выбор студента'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: queryController,
                      decoration: const InputDecoration(
                        labelText: 'Поиск по имени или логину',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) async {
                        final q = value.trim();
                        if (q.length < 2) {
                          setLocal(() => results = const []);
                          return;
                        }
                        final next = await widget.studentsRepository
                            .listStudents(query: q, active: true);
                        setLocal(() => results = next.take(30).toList());
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 260,
                      child: ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final s = results[index];
                          final label = '${s.surname} ${s.name}'.trim().isEmpty
                              ? s.login
                              : '${s.surname} ${s.name}'.trim();
                          return ListTile(
                            title: Text(label),
                            subtitle: Text(s.groupName ?? s.login),
                            onTap: () => Navigator.of(context).pop(s),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Отмена'),
                ),
              ],
            );
          },
        );
      },
    );
    queryController.dispose();
    if (selected == null) return;
    _userLabels[selected.id] = selected;
    if (widget.selectedUserIds.contains(selected.id)) return;
    widget.onChanged(
      groupIds: widget.selectedGroupIds,
      userIds: [...widget.selectedUserIds, selected.id],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.audienceMode == 'all') {
      return const Text('Аудитория: все активные студенты.');
    }
    if (_loading) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    if (_error != null) {
      return Text('Не удалось загрузить справочники: $_error');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_needGroups) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in widget.selectedGroupIds)
                InputChip(
                  label: Text(_groupLabel(id)),
                  onDeleted: widget.enabled
                      ? () => widget.onChanged(
                          groupIds: widget.selectedGroupIds
                              .where((e) => e != id)
                              .toList(),
                          userIds: widget.selectedUserIds,
                        )
                      : null,
                ),
              if (widget.enabled)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Добавить группу'),
                  onPressed: _pickGroup,
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (_needUsers) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in widget.selectedUserIds)
                InputChip(
                  label: Text(_userLabel(id)),
                  onDeleted: widget.enabled
                      ? () => widget.onChanged(
                          groupIds: widget.selectedGroupIds,
                          userIds: widget.selectedUserIds
                              .where((e) => e != id)
                              .toList(),
                        )
                      : null,
                ),
              if (widget.enabled)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Добавить студента'),
                  onPressed: _pickUser,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _SearchPickDialog<T> extends StatefulWidget {
  const _SearchPickDialog({
    required this.title,
    required this.items,
    required this.labelOf,
    required this.filter,
  });

  final String title;
  final List<T> items;
  final String Function(T) labelOf;
  final bool Function(T, String) filter;

  @override
  State<_SearchPickDialog<T>> createState() => _SearchPickDialogState<T>();
}

class _SearchPickDialogState<T> extends State<_SearchPickDialog<T>> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.items
        : widget.items.where((e) => widget.filter(e, q)).toList();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'Поиск',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 280,
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final item = filtered[index];
                  return ListTile(
                    title: Text(widget.labelOf(item)),
                    onTap: () => Navigator.of(context).pop(item),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
