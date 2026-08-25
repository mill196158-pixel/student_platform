import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/admin_backend_config.dart';
import 'group_recognition_repository.dart';

class GroupRecognitionPanel extends StatefulWidget {
  const GroupRecognitionPanel({
    super.key,
    this.repository,
    this.initialRows = const [],
    this.fileName = 'groups.xlsx',
  });

  final GroupRecognitionRepository? repository;
  final List<Map<String, dynamic>> initialRows;
  final String fileName;

  @override
  State<GroupRecognitionPanel> createState() => _GroupRecognitionPanelState();
}

class _GroupRecognitionPanelState extends State<GroupRecognitionPanel> {
  late final GroupRecognitionRepository _repository =
      widget.repository ?? _defaultRepository();
  late final TextEditingController _namesController;

  List<GroupRecognitionAcademicYear> _years = const [];
  GroupRecognitionAcademicYear? _selectedYear;
  GroupRecognitionPreview? _preview;
  final Map<String, GroupRecognitionDecision> _drafts = {};
  final Map<String, TextEditingController> _discriminators = {};
  final Map<String, TextEditingController> _reasons = {};
  bool _loadingYears = true;
  bool _busy = false;
  String? _error;
  int _inputRevision = 0;
  int _request = 0;

  GroupRecognitionRepository _defaultRepository() {
    if (AdminBackendConfig.isDemoMode) {
      return const LocalGroupRecognitionRepository();
    }
    try {
      return SupabaseGroupRecognitionRepository(
        client: Supabase.instance.client,
      );
    } catch (_) {
      return const LocalGroupRecognitionRepository();
    }
  }

  @override
  void initState() {
    super.initState();
    _namesController = TextEditingController(
      text: widget.initialRows
          .map((row) => '${row['group_name'] ?? row['name'] ?? ''}'.trim())
          .where((name) => name.isNotEmpty)
          .join('\n'),
    )..addListener(_invalidatePreview);
    _loadYears();
  }

  @override
  void dispose() {
    _namesController
      ..removeListener(_invalidatePreview)
      ..dispose();
    for (final controller in [..._discriminators.values, ..._reasons.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _clearReview() {
    _drafts.clear();
    for (final controller in [..._discriminators.values, ..._reasons.values]) {
      controller.dispose();
    }
    _discriminators.clear();
    _reasons.clear();
  }

  void _invalidatePreview() {
    if (_busy) return;
    setState(() {
      _inputRevision++;
      _preview = null;
      _clearReview();
      _error = null;
    });
  }

  Future<void> _loadYears() async {
    try {
      final years = await _repository.listAcademicYears();
      if (!mounted) return;
      setState(() {
        _years = years;
        _selectedYear = years.isEmpty
            ? null
            : years.firstWhere(
                (year) => year.isCurrent,
                orElse: () => years.first,
              );
        _loadingYears = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingYears = false;
        _error = '$error';
      });
    }
  }

  List<Map<String, dynamic>> _buildRows() {
    final names = _namesController.text
        .split(RegExp(r'\r?\n'))
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
    return [
      for (var index = 0; index < names.length; index++)
        {'source_row_key': '${index + 1}', 'group_name': names[index]},
    ];
  }

  Future<void> _startPreview() async {
    final year = _selectedYear;
    final rows = _buildRows();
    if (year == null || rows.isEmpty) {
      setState(() {
        _error = year == null
            ? 'Выберите учебный год.'
            : 'Добавьте хотя бы одно название группы.';
      });
      return;
    }
    final revision = _inputRevision;
    final request = ++_request;
    setState(() {
      _busy = true;
      _preview = null;
      _clearReview();
      _error = null;
    });
    try {
      final preview = await _repository.startPreview(
        academicYearId: year.id,
        rows: rows,
        fileName: widget.fileName,
      );
      if (!mounted || revision != _inputRevision || request != _request) return;
      setState(() {
        _preview = preview;
        _adoptSavedDecisions(preview);
      });
    } catch (error) {
      if (!mounted || revision != _inputRevision || request != _request) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  void _adoptSavedDecisions(GroupRecognitionPreview preview) {
    _clearReview();
    for (final item in preview.items) {
      final decision = item.decision;
      if (decision == null) continue;
      _drafts[item.rowId] = decision;
      _discriminators[item.rowId] = TextEditingController(
        text: decision.distinctDiscriminator,
      );
      _reasons[item.rowId] = TextEditingController(
        text: decision.distinctReason ?? '',
      );
    }
  }

  void _setDecision(
    GroupRecognitionItem item,
    GroupRecognitionDecisionAction? action,
  ) {
    if (action == null) {
      setState(() => _drafts.remove(item.rowId));
      return;
    }
    final current = _drafts[item.rowId];
    final groupId = action == GroupRecognitionDecisionAction.createGroup
        ? null
        : current?.selectedGroupId ??
              (item.candidateGroupIds.length == 1
                  ? item.candidateGroupIds.single
                  : null);
    final fixedPlanId = item.candidateGroups
        .where((candidate) => candidate.id == groupId)
        .map(
          (candidate) => candidate.profile?['curriculum_plan_id']?.toString(),
        )
        .whereType<String>()
        .firstOrNull;
    final planId =
        fixedPlanId ??
        current?.selectedPlanId ??
        (item.candidatePlanIds.length == 1
            ? item.candidatePlanIds.single
            : null);
    setState(() {
      _drafts[item.rowId] = GroupRecognitionDecision(
        previewRowId: item.rowId,
        action: action,
        selectedGroupId: groupId,
        selectedPlanId: planId,
        distinctDiscriminator: _discriminators[item.rowId]?.text.trim() ?? '',
        distinctReason: _reasons[item.rowId]?.text.trim(),
      );
    });
  }

  void _updateDecision(
    GroupRecognitionItem item, {
    String? groupId,
    String? planId,
  }) {
    final current = _drafts[item.rowId];
    if (current == null) return;
    final selectedGroupId = groupId ?? current.selectedGroupId;
    final fixedPlanId = item.candidateGroups
        .where((candidate) => candidate.id == selectedGroupId)
        .map(
          (candidate) => candidate.profile?['curriculum_plan_id']?.toString(),
        )
        .whereType<String>()
        .firstOrNull;
    final selectedCandidate = item.candidateGroups
        .where((candidate) => candidate.id == selectedGroupId)
        .firstOrNull;
    final profileNominal =
        (selectedCandidate?.profile?['nominal_semesters'] as num?)?.toInt();
    final compatiblePlanIds = item.candidatePlans
        .where(
          (plan) =>
              plan.nominalSemesters >=
                  (selectedCandidate?.maxTermSemester ?? 0) &&
              (profileNominal == null ||
                  plan.nominalSemesters == profileNominal),
        )
        .map((plan) => plan.id)
        .toList(growable: false);
    final requestedPlanId = fixedPlanId ?? planId ?? current.selectedPlanId;
    final selectedPlanId = compatiblePlanIds.contains(requestedPlanId)
        ? requestedPlanId
        : compatiblePlanIds.length == 1
        ? compatiblePlanIds.single
        : null;
    setState(() {
      _drafts[item.rowId] = GroupRecognitionDecision(
        previewRowId: item.rowId,
        action: current.action,
        selectedGroupId: selectedGroupId,
        selectedPlanId: selectedPlanId,
        distinctDiscriminator: _discriminators[item.rowId]?.text.trim() ?? '',
        distinctReason: _reasons[item.rowId]?.text.trim(),
      );
    });
  }

  Future<void> _saveDecisions() async {
    final preview = _preview;
    if (preview == null) return;
    final request = ++_request;
    final inputRevision = _inputRevision;
    final decisions = [
      for (final item in preview.items)
        if (_drafts[item.rowId] case final decision?)
          GroupRecognitionDecision(
            previewRowId: item.rowId,
            action: decision.action,
            selectedGroupId: decision.selectedGroupId,
            selectedPlanId: decision.selectedPlanId,
            distinctDiscriminator:
                _discriminators[item.rowId]?.text.trim() ?? '',
            distinctReason: _reasons[item.rowId]?.text.trim(),
          ),
    ];
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await _repository.saveDecisions(
        preview: preview,
        decisions: decisions,
      );
      if (!mounted || request != _request || inputRevision != _inputRevision) {
        return;
      }
      setState(() {
        _preview = saved;
        _adoptSavedDecisions(saved);
      });
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _confirmApply() async {
    final preview = _preview;
    if (preview == null || !preview.applyEnabled) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Применить проверенные группы?'),
        content: Text(
          'Будут применены ${preview.items.length} проверенных решений '
          '(версия ${preview.decisionRevision}). Создаются только группы и '
          'их учебные связи. Аккаунты, зачисления, предметные команды и чаты '
          'не создаются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Применить эти решения'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final request = ++_request;
    final inputRevision = _inputRevision;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final applied = await _repository.apply(preview: preview);
      if (!mounted || request != _request || inputRevision != _inputRevision) {
        return;
      }
      setState(() => _preview = applied);
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Проверка названий групп',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'Система читает параллель слева, код программы в середине и курс '
          'справа. Год поступления вычисляется на сервере.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 14),
        if (_loadingYears)
          const LinearProgressIndicator()
        else
          DropdownButtonFormField<GroupRecognitionAcademicYear>(
            key: ValueKey(_selectedYear?.id),
            initialValue: _selectedYear,
            decoration: const InputDecoration(
              labelText: 'Учебный год проверки',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final year in _years)
                DropdownMenuItem(
                  value: year,
                  child: Text(
                    '${year.name} · начало ${year.startYear}'
                    '${year.isCurrent ? ' · текущий' : ''}',
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (year) {
                    setState(() {
                      _selectedYear = year;
                      _inputRevision++;
                      _preview = null;
                      _clearReview();
                    });
                  },
          ),
        const SizedBox(height: 10),
        SizedBox(
          height: 96,
          child: TextField(
            controller: _namesController,
            enabled: !_busy,
            maxLines: null,
            expands: true,
            decoration: const InputDecoration(
              labelText: 'По одной группе в строке',
              hintText: '1-СбПГС-2\n2-СДПГС-2',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: _busy || _loadingYears ? null : _startPreview,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Проверить'),
            ),
            if (preview != null && preview.results.isEmpty)
              OutlinedButton.icon(
                onPressed: _busy ? null : _saveDecisions,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Сохранить решения'),
              ),
            if (preview?.applyEnabled == true && preview!.results.isEmpty)
              FilledButton.icon(
                onPressed: _busy ? null : _confirmApply,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Применить после подтверждения'),
              ),
            if (AdminBackendConfig.isDemoMode)
              const Chip(label: Text('Демо: применение отключено')),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          MaterialBanner(
            content: Text(_error!),
            actions: [
              TextButton(
                onPressed: () => setState(() => _error = null),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: preview == null
              ? const Center(
                  child: Text(
                    'Проверьте список, затем выберите и сохраните решение '
                    'для каждой строки без ошибок.',
                    textAlign: TextAlign.center,
                  ),
                )
              : preview.results.isNotEmpty
              ? _ApplySummary(preview: preview)
              : _RecognitionResults(
                  preview: preview,
                  decisions: _drafts,
                  discriminators: _discriminators,
                  reasons: _reasons,
                  onAction: _setDecision,
                  onSelection: _updateDecision,
                ),
        ),
      ],
    );
  }
}

class _RecognitionResults extends StatelessWidget {
  const _RecognitionResults({
    required this.preview,
    required this.decisions,
    required this.discriminators,
    required this.reasons,
    required this.onAction,
    required this.onSelection,
  });

  final GroupRecognitionPreview preview;
  final Map<String, GroupRecognitionDecision> decisions;
  final Map<String, TextEditingController> discriminators;
  final Map<String, TextEditingController> reasons;
  final void Function(GroupRecognitionItem, GroupRecognitionDecisionAction?)
  onAction;
  final void Function(GroupRecognitionItem, {String? groupId, String? planId})
  onSelection;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            Chip(label: Text('Всего: ${preview.summary['total'] ?? 0}')),
            Chip(
              label: Text(
                'Нужны решения: ${preview.summary['needs_decision'] ?? 0}',
              ),
            ),
            Chip(label: Text('Ошибки: ${preview.summary['blocked'] ?? 0}')),
            Chip(label: Text('Сохранено: ${preview.decisionRevision}')),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: preview.items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final item = preview.items[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            item.isBlocked
                                ? Icons.warning_amber_rounded
                                : Icons.check_circle_outline,
                            color: item.isBlocked
                                ? Colors.orange
                                : Colors.green,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              item.rawGroupName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(_classificationLabel(item.classification)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Параллель ${item.parallelNumber ?? '—'} · '
                        'курс ${item.courseNumber ?? '—'} · '
                        'поступление ${item.derivedAdmissionYear ?? '—'}',
                        style: const TextStyle(color: Colors.black54),
                      ),
                      if (item.warnings.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          _warningText(item.warnings),
                          style: const TextStyle(color: Color(0xFF8B5A00)),
                        ),
                      ],
                      if (item.isActionable) ...[
                        const Divider(height: 22),
                        _DecisionEditor(
                          item: item,
                          decision: decisions[item.rowId],
                          discriminator: discriminators.putIfAbsent(
                            item.rowId,
                            TextEditingController.new,
                          ),
                          reason: reasons.putIfAbsent(
                            item.rowId,
                            TextEditingController.new,
                          ),
                          onAction: (value) => onAction(item, value),
                          onGroup: (value) => onSelection(item, groupId: value),
                          onPlan: (value) => onSelection(item, planId: value),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DecisionEditor extends StatelessWidget {
  const _DecisionEditor({
    required this.item,
    required this.decision,
    required this.discriminator,
    required this.reason,
    required this.onAction,
    required this.onGroup,
    required this.onPlan,
  });

  final GroupRecognitionItem item;
  final GroupRecognitionDecision? decision;
  final TextEditingController discriminator;
  final TextEditingController reason;
  final ValueChanged<GroupRecognitionDecisionAction?> onAction;
  final ValueChanged<String?> onGroup;
  final ValueChanged<String?> onPlan;

  List<GroupRecognitionDecisionAction> get _actions =>
      switch (item.classification) {
        'exact_group' ||
        'exact_alias' => const [GroupRecognitionDecisionAction.reuseGroup],
        'semantic_duplicate' => GroupRecognitionDecisionAction.values,
        _ => const [GroupRecognitionDecisionAction.createGroup],
      };

  @override
  Widget build(BuildContext context) {
    final action = decision?.action;
    final needsGroup =
        action == GroupRecognitionDecisionAction.reuseGroup ||
        action == GroupRecognitionDecisionAction.addAlias;
    final needsDistinct =
        item.classification == 'semantic_duplicate' &&
        action == GroupRecognitionDecisionAction.createGroup;
    final selectedCandidate = item.candidateGroups
        .where((candidate) => candidate.id == decision?.selectedGroupId)
        .firstOrNull;
    final profileNominal =
        (selectedCandidate?.profile?['nominal_semesters'] as num?)?.toInt();
    final availablePlans = item.candidatePlans
        .where((plan) {
          if (plan.nominalSemesters <
              (selectedCandidate?.maxTermSemester ?? 0)) {
            return false;
          }
          return profileNominal == null ||
              plan.nominalSemesters == profileNominal;
        })
        .toList(growable: false);
    final fixedPlanId = item.candidateGroups
        .where((candidate) => candidate.id == decision?.selectedGroupId)
        .map(
          (candidate) => candidate.profile?['curriculum_plan_id']?.toString(),
        )
        .whereType<String>()
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<GroupRecognitionDecisionAction>(
          initialValue: action,
          decoration: const InputDecoration(
            labelText: 'Решение',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final value in _actions)
              DropdownMenuItem(value: value, child: Text(_actionLabel(value))),
          ],
          onChanged: onAction,
        ),
        if (needsGroup) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: decision?.selectedGroupId,
            decoration: const InputDecoration(
              labelText: 'Существующая группа',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final id in item.candidateGroupIds)
                DropdownMenuItem(
                  value: id,
                  child: Text(
                    item.candidateGroups
                            .where((value) => value.id == id)
                            .map((value) => value.label)
                            .firstOrNull ??
                        'Группа-кандидат',
                  ),
                ),
            ],
            onChanged: onGroup,
          ),
        ],
        if (action != null &&
            item.classification != 'exact_group' &&
            item.classification != 'exact_alias' &&
            fixedPlanId == null &&
            (item.candidatePlanIds.length > 1 ||
                item.classification == 'ambiguous_plan')) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: decision?.selectedPlanId,
            decoration: const InputDecoration(
              labelText: 'Учебный план',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final plan in availablePlans)
                DropdownMenuItem(value: plan.id, child: Text(plan.label)),
            ],
            onChanged: onPlan,
          ),
        ],
        if (needsDistinct) ...[
          const SizedBox(height: 8),
          TextField(
            controller: discriminator,
            decoration: const InputDecoration(
              labelText: 'Чем группа отличается',
              hintText: 'Например: целевой набор',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: reason,
            decoration: const InputDecoration(
              labelText: 'Почему нужна отдельная группа',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }
}

class _ApplySummary extends StatelessWidget {
  const _ApplySummary({required this.preview});
  final GroupRecognitionPreview preview;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const ListTile(
          leading: Icon(Icons.check_circle, color: Colors.green),
          title: Text('Решения применены'),
          subtitle: Text(
            'Созданы или связаны только группы, названия и учебные профили.',
          ),
        ),
        for (final result in preview.results)
          ListTile(
            title: Text(result.groupName),
            subtitle: Text(
              '${_actionWireLabel(result.action)} · ${result.planLabel}\n'
              'Название: ${_outcomeLabel(result.aliasOutcome)} · '
              'идентичность: ${_outcomeLabel(result.identityOutcome)} · '
              'профиль: ${_outcomeLabel(result.profileOutcome)}',
            ),
            isThreeLine: true,
          ),
      ],
    );
  }
}

String _classificationLabel(String value) => switch (value) {
  'exact_group' => 'Точное совпадение',
  'exact_alias' => 'Подтверждённый вариант',
  'semantic_duplicate' => 'Возможный дубликат',
  'new_candidate' => 'Новая группа',
  'ambiguous_plan' => 'Нужно выбрать план',
  'no_plan' => 'Нет подходящего плана',
  'program_unregistered' => 'Код программы не подтверждён',
  'parser_blocked' => 'Название не распознано',
  _ => 'Конфликт данных',
};

String _warningText(List<String> warnings) => warnings
    .map((value) {
      return switch (value) {
        'multiple_plan_versions_require_choice' =>
          'Выберите одну подтверждённую версию учебного плана.',
        'matching_reviewed_plan_not_found' =>
          'Для этого года поступления нет подтверждённого плана.',
        'group_identity_conflict' =>
          'Учебная идентичность найденной группы не совпадает.',
        'group_profile_conflict' =>
          'Учебный профиль найденной группы несовместим.',
        'group_plan_conflict' => 'У группы уже указан другой учебный план.',
        'group_nominal_semesters_conflict' =>
          'Продолжительность обучения группы и плана различается.',
        'group_semester_exceeds_plan' =>
          'У группы есть семестр за пределами выбранного плана.',
        'semantic_candidates_incompatible' =>
          'Найденные похожие группы имеют несовместимый учебный профиль или план.',
        _ => 'Строку нельзя применить без дополнительной проверки.',
      };
    })
    .join(' ');

String _actionLabel(GroupRecognitionDecisionAction value) => switch (value) {
  GroupRecognitionDecisionAction.reuseGroup =>
    'Использовать существующую группу',
  GroupRecognitionDecisionAction.addAlias =>
    'Использовать группу и сохранить это название',
  GroupRecognitionDecisionAction.createGroup => 'Создать отдельную группу',
};

String _actionWireLabel(String value) => switch (value) {
  'reuse_group' => 'Использована существующая группа',
  'add_alias' => 'Сохранён новый вариант названия',
  'create_group' => 'Создана новая группа',
  _ => 'Решение применено',
};

String _outcomeLabel(String value) => switch (value) {
  'created' => 'создано',
  'existing' => 'уже было',
  'retained' => 'сохранён',
  'plan_bound' => 'план привязан',
  'not_requested' => 'без изменений',
  _ => value,
};
