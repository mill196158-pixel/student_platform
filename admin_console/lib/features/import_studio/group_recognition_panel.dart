import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/admin_backend_config.dart';
import 'group_recognition_repository.dart';

enum GroupDuplicateReviewIntent { reuseGroup, addAlias }

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
  bool _loadingYears = true;
  bool _busy = false;
  String? _error;
  int _revision = 0;
  int _request = 0;
  final Map<String, GroupDuplicateReviewIntent> _reviewIntents = {};

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
    super.dispose();
  }

  void _invalidatePreview() {
    if (_busy) return;
    setState(() {
      _revision++;
      _preview = null;
      _reviewIntents.clear();
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
    if (year == null) {
      setState(() => _error = 'Выберите учебный год.');
      return;
    }
    if (rows.isEmpty) {
      setState(() => _error = 'Добавьте хотя бы одно название группы.');
      return;
    }
    final revision = _revision;
    final request = ++_request;
    setState(() {
      _busy = true;
      _preview = null;
      _reviewIntents.clear();
      _error = null;
    });
    try {
      final preview = await _repository.startPreview(
        academicYearId: year.id,
        rows: rows,
        fileName: widget.fileName,
      );
      if (!mounted || revision != _revision || request != _request) return;
      setState(() => _preview = preview);
    } catch (error) {
      if (!mounted || revision != _revision || request != _request) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Проверка названий групп',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'Система читает номер параллели слева, код программы в середине '
          'и курс справа. Год поступления вычисляется на сервере.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 16),
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
                      _revision++;
                      _preview = null;
                      _reviewIntents.clear();
                      _error = null;
                    });
                  },
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 112,
          child: TextField(
            controller: _namesController,
            enabled: !_busy,
            maxLines: null,
            expands: true,
            decoration: const InputDecoration(
              labelText: 'По одной группе в строке',
              hintText: '1-СбПГС-2\n2-СДПГС-2',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy || _loadingYears ? null : _startPreview,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined),
              label: const Text('Быстрая проверка'),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Сохранение пока отключено: это безопасный preview без '
                'изменения групп и аккаунтов.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
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
        const SizedBox(height: 12),
        Expanded(
          child: _preview == null
              ? const Center(
                  child: Text(
                    'Нажмите «Быстрая проверка», чтобы увидеть курс, '
                    'год поступления, программу, план и дубликаты.',
                    textAlign: TextAlign.center,
                  ),
                )
              : _RecognitionResults(
                  preview: _preview!,
                  reviewIntents: _reviewIntents,
                  onIntentChanged: (item, intent) {
                    final preview = _preview;
                    if (preview == null) return;
                    final key = '${preview.previewId}:${item.sourceRowKey}';
                    setState(() {
                      if (intent == null) {
                        _reviewIntents.remove(key);
                      } else {
                        _reviewIntents[key] = intent;
                      }
                    });
                  },
                ),
        ),
      ],
    );
  }
}

class _RecognitionResults extends StatelessWidget {
  const _RecognitionResults({
    required this.preview,
    required this.reviewIntents,
    required this.onIntentChanged,
  });

  final GroupRecognitionPreview preview;
  final Map<String, GroupDuplicateReviewIntent> reviewIntents;
  final void Function(
    GroupRecognitionItem item,
    GroupDuplicateReviewIntent? intent,
  )
  onIntentChanged;

  @override
  Widget build(BuildContext context) {
    final summary = preview.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('Всего: ${summary['total'] ?? 0}')),
            Chip(label: Text('Найдены: ${summary['exact'] ?? 0}')),
            Chip(label: Text('Новые: ${summary['new_candidate'] ?? 0}')),
            Chip(label: Text('Нужна проверка: ${summary['blocked'] ?? 0}')),
            const Chip(
              avatar: Icon(Icons.lock_outline, size: 18),
              label: Text('Только preview'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: preview.items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final item = preview.items[index];
              final intentKey = '${preview.previewId}:${item.sourceRowKey}';
              return Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      leading: Icon(
                        item.isBlocked
                            ? Icons.warning_amber_rounded
                            : Icons.check_circle_outline,
                        color: item.isBlocked ? Colors.orange : Colors.green,
                      ),
                      title: Text(item.rawGroupName),
                      subtitle: Text(
                        'Параллель: ${item.parallelNumber ?? '—'} · '
                        'код: ${item.programAliasKey ?? '—'} · '
                        'курс: ${item.courseNumber ?? '—'} · '
                        'поступление: ${item.derivedAdmissionYear ?? '—'}\n'
                        '${_classificationLabel(item.classification)}'
                        '${item.warnings.isEmpty ? '' : ' · ${item.warnings.join(', ')}'}',
                      ),
                      isThreeLine: true,
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('групп: ${item.candidateGroupIds.length}'),
                          Text('планов: ${item.candidatePlanIds.length}'),
                        ],
                      ),
                    ),
                    if (_showsDuplicateReview(item))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                        child: _DuplicateIntentReview(
                          item: item,
                          value: reviewIntents[intentKey],
                          onChanged: (intent) => onIntentChanged(item, intent),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  bool _showsDuplicateReview(GroupRecognitionItem item) {
    return const {
      'exact_group',
      'exact_alias',
      'semantic_duplicate',
      'ambiguous_plan',
    }.contains(item.classification);
  }

  String _classificationLabel(String value) {
    return switch (value) {
      'exact_group' => 'Точная существующая группа',
      'exact_alias' => 'Найдена по подтверждённому варианту названия',
      'semantic_duplicate' => 'Найден смысловой дубликат',
      'new_candidate' => 'Можно создать после подтверждения',
      'ambiguous_plan' => 'Нужно выбрать версию учебного плана',
      'no_plan' => 'Подходящий проверенный план не найден',
      'program_unregistered' => 'Код программы ещё не подтверждён',
      'parser_blocked' => 'Формат названия не распознан',
      _ => 'Конфликт: требуется ручная проверка',
    };
  }
}

class _DuplicateIntentReview extends StatelessWidget {
  const _DuplicateIntentReview({
    required this.item,
    required this.value,
    required this.onChanged,
  });

  final GroupRecognitionItem item;
  final GroupDuplicateReviewIntent? value;
  final ValueChanged<GroupDuplicateReviewIntent?> onChanged;

  bool get _hasUniqueCandidate => item.candidateGroupIds.length == 1;
  bool get _canReuse =>
      _hasUniqueCandidate &&
      const {
        'exact_group',
        'exact_alias',
        'semantic_duplicate',
      }.contains(item.classification);
  bool get _canAddAlias =>
      _hasUniqueCandidate && item.classification == 'semantic_duplicate';

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8D7A9)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Предлагаемое решение по дублю',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Локальная пометка для проверки — не сохраняется и не '
              'применяется. После изменения списка или года выбор сбросится.',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (!_hasUniqueCandidate)
              Text(
                item.classification == 'ambiguous_plan'
                    ? 'Сначала нужно выбрать версию учебного плана; решение '
                          'по группе недоступно.'
                    : 'Нельзя выбрать действие: сервер не нашёл ровно одну '
                          'группу-кандидата.',
                style: const TextStyle(color: Color(0xFF8B5A00)),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Использовать найденную группу'),
                  selected: value == GroupDuplicateReviewIntent.reuseGroup,
                  onSelected: _canReuse
                      ? (selected) => onChanged(
                          selected
                              ? GroupDuplicateReviewIntent.reuseGroup
                              : null,
                        )
                      : null,
                ),
                ChoiceChip(
                  label: const Text('Добавить это название как вариант'),
                  selected: value == GroupDuplicateReviewIntent.addAlias,
                  onSelected: _canAddAlias
                      ? (selected) => onChanged(
                          selected ? GroupDuplicateReviewIntent.addAlias : null,
                        )
                      : null,
                ),
                const Tooltip(
                  message:
                      'Нужны дискриминатор, причина, аудит и server apply.',
                  child: Chip(
                    avatar: Icon(Icons.lock_outline, size: 16),
                    label: Text('Создать отдельную — недоступно'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
