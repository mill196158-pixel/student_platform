import 'package:flutter/material.dart';

import 'group_space_organizer_models.dart';
import 'students_repository.dart';

/// Group-space organizer management embedded in Students / Groups (Stage 13.5).
class GroupSpaceOrganizerDialog extends StatefulWidget {
  const GroupSpaceOrganizerDialog({
    super.key,
    required this.group,
    required this.repository,
    required this.canManage,
  });

  final GroupItem group;
  final StudentsRepository repository;
  final bool canManage;

  static Future<void> open(
    BuildContext context, {
    required GroupItem group,
    required StudentsRepository repository,
    required bool canManage,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => GroupSpaceOrganizerDialog(
        group: group,
        repository: repository,
        canManage: canManage,
      ),
    );
  }

  @override
  State<GroupSpaceOrganizerDialog> createState() =>
      _GroupSpaceOrganizerDialogState();
}

class _GroupSpaceOrganizerDialogState extends State<GroupSpaceOrganizerDialog> {
  bool _loading = true;
  String? _error;
  String? _success;
  GroupSpaceOrganizerState? _state;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await widget.repository.listGroupSpaceOrganizerState(
        widget.group.id,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить состав группы: $e';
      });
    }
  }

  Future<void> _confirmAndSet({
    required GroupSpaceMemberOrganizer member,
    required bool isOrganizer,
  }) async {
    final action = isOrganizer
        ? 'Назначить организатором'
        : 'Снять права организатора';
    final detail = isOrganizer
        ? 'Выдать ${member.displayName} explicit grant организатора '
              'постоянного пространства группы ${widget.group.name}?'
        : 'Снять только explicit grant у ${member.displayName}? '
              'Роль starosta/owner активной предметной команды не затрагивается.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _loading = true;
      _error = null;
      _success = null;
    });
    try {
      await widget.repository.setGroupSpaceOrganizer(
        groupId: widget.group.id,
        userId: member.userId,
        isOrganizer: isOrganizer,
      );
      final state = await widget.repository.listGroupSpaceOrganizerState(
        widget.group.id,
      );
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
        _success = isOrganizer
            ? '${member.displayName} назначен организатором'
            : 'Explicit grant снят у ${member.displayName}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Ошибка изменения прав: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final organizers = state?.organizers ?? const [];
    final members = state?.members ?? const [];
    final canManage =
        widget.canManage && (state?.canManage ?? widget.canManage);

    return AlertDialog(
      title: Text('Организаторы · ${widget.group.name}'),
      content: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Постоянное пространство группы. Источник права: '
              'explicit grant или starosta/owner активной предметной команды.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_success != null)
              MaterialBanner(
                content: Text(_success!),
                backgroundColor: Colors.green.shade50,
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _success = null),
                    child: const Text('OK'),
                  ),
                ],
              ),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                backgroundColor: Colors.red.shade50,
                actions: [
                  TextButton(onPressed: _reload, child: const Text('Повтор')),
                ],
              ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (state == null)
              const Expanded(
                child: Center(child: Text('Нет данных по пространству группы')),
              )
            else if (members.isEmpty)
              const Expanded(
                child: Center(child: Text('В группе нет активных участников')),
              )
            else
              Expanded(
                child: ListView(
                  children: [
                    Text(
                      'Текущие организаторы',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    if (organizers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('Организатор не назначен'),
                      )
                    else
                      ...organizers.map(
                        (m) => ListTile(
                          dense: true,
                          title: Text(m.displayName),
                          subtitle: Text('Источник: ${m.sourceLabel}'),
                          trailing: m.hasAdminGrant && canManage
                              ? TextButton(
                                  onPressed: () => _confirmAndSet(
                                    member: m,
                                    isOrganizer: false,
                                  ),
                                  child: const Text('Снять права'),
                                )
                              : null,
                        ),
                      ),
                    if (state.assistantsSupported) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Помощники',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const Text('Модель помощников пока не используется.'),
                    ],
                    const Divider(height: 24),
                    Text(
                      'Участники группы',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    ...members.map((m) {
                      final showAssign =
                          canManage && !m.hasAdminGrant && m.isActive;
                      final showRevoke = canManage && m.hasAdminGrant;
                      return ListTile(
                        title: Text(m.displayName),
                        subtitle: Text(
                          [
                            m.login,
                            m.isActive ? 'active' : 'blocked',
                            if (m.isOrganizer) 'источник: ${m.sourceLabel}',
                          ].join(' · '),
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            if (m.isOrganizer)
                              Chip(
                                label: Text(
                                  m.hasSubjectTeamAuthority && !m.hasAdminGrant
                                      ? 'starosta'
                                      : 'organizer',
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                            if (showAssign)
                              TextButton(
                                onPressed: () => _confirmAndSet(
                                  member: m,
                                  isOrganizer: true,
                                ),
                                child: const Text('Назначить организатором'),
                              ),
                            if (showRevoke)
                              TextButton(
                                onPressed: () => _confirmAndSet(
                                  member: m,
                                  isOrganizer: false,
                                ),
                                child: const Text('Снять права организатора'),
                              ),
                            if (canManage &&
                                m.hasSubjectTeamAuthority &&
                                !m.hasAdminGrant)
                              const Tooltip(
                                message:
                                    'Права из активной предметной команды; '
                                    'explicit grant не снимается, потому что его нет',
                                child: Icon(Icons.info_outline, size: 18),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _reload, child: const Text('Обновить')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
