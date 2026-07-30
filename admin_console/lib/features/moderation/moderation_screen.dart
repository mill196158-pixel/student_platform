import 'package:flutter/material.dart';

import 'package:student_ui/student_ui.dart';



import '../../core/auth/admin_backend_config.dart';

import '../../core/auth/admin_session_controller.dart';

import 'moderation_queue_item.dart';

import 'moderation_repository.dart';



class ModerationScreen extends StatefulWidget {

  const ModerationScreen({

    super.key,

    required this.session,

    ModerationRepository? repository,

  }) : _repository = repository;



  final AdminSessionController session;

  final ModerationRepository? _repository;



  @override

  State<ModerationScreen> createState() => _ModerationScreenState();

}



class _ModerationScreenState extends State<ModerationScreen> {

  late ModerationRepository _repo;

  int _tabIndex = 0;

  String _statusFilter = 'open';

  ModerationQueueDomain? _domainFilter;

  List<UnifiedModerationQueueItem> _unifiedItems = const [];

  List<LegacyReviewQueueItem> _legacyItems = const [];

  bool _loading = true;

  String? _error;

  final _authorFilter = TextEditingController();

  final _assigneeFilter = TextEditingController();

  final _priorityFilter = TextEditingController();

  DateTime? _sinceFilter;



  @override

  void initState() {

    super.initState();

    _repo = widget._repository ??

        (AdminBackendConfig.isDemoMode || widget.session.isLocalPrototype

            ? LocalModerationRepository()

            : SupabaseModerationRepository());

    _load();

  }



  @override

  void dispose() {

    _authorFilter.dispose();

    _assigneeFilter.dispose();

    _priorityFilter.dispose();

    super.dispose();

  }



  int? get _minPriorityFilter {

    final raw = _priorityFilter.text.trim();

    if (raw.isEmpty) return null;

    return int.tryParse(raw);

  }



  bool get _canModerate =>

      widget.session.isLocalPrototype ||

      widget.session.capabilities.can('moderation.action') ||

      widget.session.capabilities.can('moderation.write');



  Future<void> _load() async {

    setState(() {

      _loading = true;

      _error = null;

    });

    try {

      if (_tabIndex == 0) {

        _unifiedItems = await _repo.listUnifiedQueue(

          domains: _domainFilter == null ? null : [_domainFilter!],

          status: _statusFilter,

          since: _sinceFilter,

          authorUserId: _authorFilter.text.trim().isEmpty

              ? null

              : _authorFilter.text.trim(),

          assigneeUserId: _assigneeFilter.text.trim().isEmpty

              ? null

              : _assigneeFilter.text.trim(),

          minPriority: _minPriorityFilter,

        );

      } else {

        final legacyStatus = switch (_statusFilter) {

          'closed' => 'hidden',

          'all' => 'all',

          _ => 'queue',

        };

        _legacyItems = await _repo.listLegacyReviewQueue(status: legacyStatus);

      }

    } on ModerationRepositoryException catch (error) {

      _error = error.message;

      _unifiedItems = const [];

      _legacyItems = const [];

    } finally {

      if (mounted) setState(() => _loading = false);

    }

  }



  Future<String?> _promptReason(String title, {bool optional = false}) async {

    final reason = TextEditingController();

    final ok = await showDialog<bool>(

      context: context,

      builder: (context) => AlertDialog(

        title: Text(title),

        content: TextField(

          controller: reason,

          maxLength: 500,

          decoration: InputDecoration(

            labelText: optional

                ? 'Комментарий (необязательно)'

                : 'Причина решения (обязательно)',

            helperText:

                'Автор не публикуется. Текст причины сохраняется в журнале модерации.',

          ),

        ),

        actions: [

          TextButton(

            onPressed: () => Navigator.pop(context, false),

            child: const Text('Отмена'),

          ),

          FilledButton(

            onPressed: () {

              if (!optional && reason.text.trim().isEmpty) return;

              Navigator.pop(context, true);

            },

            child: const Text('Подтвердить'),

          ),

        ],

      ),

    );

    if (ok != true) return null;

    final text = reason.text.trim();

    return text.isEmpty && optional ? '' : text;

  }



  Future<void> _showHistory(UnifiedModerationQueueItem item) async {

    List<ModerationHistoryEntry> entries;

    if (item.domain == ModerationQueueDomain.review) {

      entries = await _repo.listReviewHistory(reviewId: item.entityId);

    } else if (item.domain == ModerationQueueDomain.vacancy) {

      entries = await _repo.listVacancyHistory(vacancyId: item.entityId);

    } else {

      entries = const [];

    }

    if (!mounted) return;

    await showDialog<void>(

      context: context,

      builder: (context) => AlertDialog(

        title: Text('История · ${item.domain.labelRu}'),

        content: SizedBox(

          width: 420,

          child: entries.isEmpty

              ? const Text('Записей пока нет')

              : ListView.separated(

                  shrinkWrap: true,

                  itemCount: entries.length,

                  separatorBuilder: (_, __) => const Divider(height: 12),

                  itemBuilder: (context, index) {

                    final entry = entries[index];

                    final statusLine = [

                      if (entry.fromStatus != null) entry.fromStatus,

                      if (entry.toStatus != null) '→ ${entry.toStatus}',

                    ].join(' ');

                    return Text(

                      '${entry.action}'

                      '${statusLine.isEmpty ? '' : ' ($statusLine)'}\n'

                      '${entry.reasonText ?? '—'}',

                    );

                  },

                ),

        ),

        actions: [

          TextButton(

            onPressed: () => Navigator.pop(context),

            child: const Text('Закрыть'),

          ),

        ],

      ),

    );

  }



  Future<void> _moderateUnified(UnifiedModerationQueueItem item) async {

    if (!_canModerate) return;



    final action = await _pickDomainAction(item.domain, item.status);

    if (action == null) return;



    final title = '${item.domain.labelRu}: действие';

    final reasonOptional = action == 'take_in_moderation' ||

        action == 'approve' ||

        action == 'resolve';

    final reason = await _promptReason(title, optional: reasonOptional);

    if (reason == null) return;

    if (!reasonOptional && reason.isEmpty) return;



    await _repo.applyUnifiedAction(

      domain: item.domain,

      entityId: item.entityId,

      action: action,

      reason: reason,

      expectedRowVersion: item.rowVersion,

    );

    await _load();

  }



  Future<String?> _pickDomainAction(

    ModerationQueueDomain domain,

    String status,

  ) async {

    final options = switch (domain) {

      ModerationQueueDomain.review => [

          if (status == ReviewModerationStatus.pending.wireValue ||

              status == 'submitted')

            ('approve', 'Одобрить'),

          if (status == ReviewModerationStatus.pending.wireValue ||

              status == 'submitted') ...[

            ('reject', 'Отклонить'),

            ('request_clarification', 'Запросить уточнение'),

          ],

          if (status == ReviewModerationStatus.approved.wireValue ||

              status == 'active')

            ('remove_violation', 'Снять за нарушение'),

          if (status == ReviewModerationStatus.rejected.wireValue ||

              status == 'hidden')

            ('restore', 'Восстановить'),

        ],

      ModerationQueueDomain.reviewReport ||

      ModerationQueueDomain.vacancyReport =>

        const [

          ('resolve', 'Принять жалобу'),

          ('reject', 'Отклонить жалобу'),

        ],

      ModerationQueueDomain.vacancy => [

          if (status == 'submitted') ('take_in_moderation', 'Взять в работу'),

          if (status == 'in_moderation') ('approve', 'Одобрить'),

          if (status == 'submitted' || status == 'in_moderation')

            ('reject', 'Отклонить'),

          if (status == 'submitted' || status == 'in_moderation')

            ('request_clarification', 'Запросить уточнение'),

        ],

      ModerationQueueDomain.contentCorrection => const [

          ('resolve', 'Принять'),

          ('reject', 'Отклонить'),

        ],

    };

    if (options.isEmpty) return null;



    return showDialog<String>(

      context: context,

      builder: (context) => SimpleDialog(

        title: Text('Действие · ${domain.labelRu}'),

        children: [

          for (final option in options)

            SimpleDialogOption(

              onPressed: () => Navigator.pop(context, option.$1),

              child: Text(option.$2),

            ),

        ],

      ),

    );

  }



  Future<void> _moderateLegacy(String reviewId, String action) async {

    if (!_canModerate) return;



    final title = action == 'hide' ? 'Скрыть отзыв' : 'Восстановить отзыв';

    final reason = await _promptReason(title);

    if (reason == null || reason.isEmpty) return;



    await _repo.moderateLegacyReview(

      reviewId: reviewId,

      action: action,

      reason: reason,

    );

    await _load();

  }



  Future<void> _pickSinceDate() async {

    final picked = await showDatePicker(

      context: context,

      initialDate: _sinceFilter ?? DateTime.now(),

      firstDate: DateTime(2024),

      lastDate: DateTime.now().add(const Duration(days: 1)),

    );

    if (picked == null) return;

    setState(() => _sinceFilter = picked);

    await _load();

  }



  bool _canActOn(UnifiedModerationQueueItem item) {

    return item.domain == ModerationQueueDomain.review ||

        item.domain == ModerationQueueDomain.reviewReport ||

        item.domain == ModerationQueueDomain.vacancy ||

        item.domain == ModerationQueueDomain.vacancyReport ||

        item.domain == ModerationQueueDomain.contentCorrection;

  }



  bool _canShowHistory(UnifiedModerationQueueItem item) {

    return item.domain == ModerationQueueDomain.review ||

        item.domain == ModerationQueueDomain.vacancy;

  }



  @override

  Widget build(BuildContext context) {

    return Column(

      crossAxisAlignment: CrossAxisAlignment.start,

      children: [

        Text(

          'Модерация',

          style: Theme.of(

            context,

          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),

        ),

        const SizedBox(height: 6),

        const Text(

          'Единая очередь Stage 18 (отзывы, жалобы, вакансии, исправления) '

          'и legacy-очередь Stage 13.6. Автор виден только модераторам.',

        ),

        const SizedBox(height: 12),

        SegmentedButton<int>(

          segments: const [

            ButtonSegment(value: 0, label: Text('Единая очередь')),

            ButtonSegment(value: 1, label: Text('Отзывы 13.6')),

          ],

          selected: {_tabIndex},

          onSelectionChanged: (value) {

            setState(() => _tabIndex = value.first);

            _load();

          },

        ),

        const SizedBox(height: 12),

        Wrap(

          spacing: 12,

          runSpacing: 8,

          crossAxisAlignment: WrapCrossAlignment.center,

          children: [

            DropdownButton<String>(

              value: _statusFilter,

              items: const [

                DropdownMenuItem(value: 'open', child: Text('Открытые')),

                DropdownMenuItem(value: 'closed', child: Text('Закрытые')),

                DropdownMenuItem(value: 'all', child: Text('Все')),

              ],

              onChanged: (value) {

                _statusFilter = value ?? 'open';

                _load();

              },

            ),

            if (_tabIndex == 0) ...[

              DropdownButton<ModerationQueueDomain?>(

                value: _domainFilter,

                hint: const Text('Все типы'),

                items: [

                  const DropdownMenuItem<ModerationQueueDomain?>(

                    value: null,

                    child: Text('Все типы'),

                  ),

                  for (final domain in ModerationQueueDomain.values)

                    DropdownMenuItem(

                      value: domain,

                      child: Text(domain.labelRu),

                    ),

                ],

                onChanged: (value) {

                  _domainFilter = value;

                  _load();

                },

              ),

              SizedBox(

                width: 160,

                child: TextField(

                  controller: _authorFilter,

                  decoration: const InputDecoration(

                    labelText: 'Автор (UUID)',

                    isDense: true,

                  ),

                  onSubmitted: (_) => _load(),

                ),

              ),

              SizedBox(

                width: 160,

                child: TextField(

                  controller: _assigneeFilter,

                  decoration: const InputDecoration(

                    labelText: 'Последний модератор (UUID)',

                    isDense: true,

                  ),

                  onSubmitted: (_) => _load(),

                ),

              ),

              SizedBox(

                width: 100,

                child: TextField(

                  controller: _priorityFilter,

                  decoration: const InputDecoration(

                    labelText: 'Приоритет ≥',

                    isDense: true,

                  ),

                  keyboardType: TextInputType.number,

                  onSubmitted: (_) => _load(),

                ),

              ),

              OutlinedButton(

                onPressed: _pickSinceDate,

                child: Text(

                  _sinceFilter == null

                      ? 'С даты'

                      : 'С ${_sinceFilter!.toIso8601String().substring(0, 10)}',

                ),

              ),

              if (_sinceFilter != null)

                TextButton(

                  onPressed: () {

                    setState(() => _sinceFilter = null);

                    _load();

                  },

                  child: const Text('Сброс даты'),

                ),

              FilledButton.tonal(onPressed: _load, child: const Text('Применить')),

            ],

          ],

        ),

        if (_error != null) ...[

          const SizedBox(height: 8),

          Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C))),

        ],

        const SizedBox(height: 12),

        Expanded(

          child: Card(

            child: _loading

                ? const Center(child: CircularProgressIndicator())

                : _tabIndex == 0

                ? _buildUnifiedList(_canModerate)

                : _buildLegacyList(_canModerate),

          ),

        ),

      ],

    );

  }



  Widget _buildUnifiedList(bool canWrite) {

    if (_unifiedItems.isEmpty) {

      return const Center(child: Text('Очередь пуста'));

    }

    return ListView.separated(

      itemCount: _unifiedItems.length,

      separatorBuilder: (_, __) => const Divider(height: 1),

      itemBuilder: (context, index) {

        final item = _unifiedItems[index];

        final authorLine = item.authorLabel ?? item.authorUserId ?? '—';

        return ListTile(

          title: Text('${item.domain.labelRu} · ${item.title}'),

          subtitle: Text(

            '${item.detail ?? '—'}\n'

            'Статус: ${item.status}'

            '${item.openReports > 0 ? ' · жалоб: ${item.openReports}' : ''}'

            '${item.priority != null ? ' · приоритет: ${item.priority}' : ''}\n'

            'Автор (мод.): $authorLine'

            '${item.assigneeUserId != null ? ' · посл. мод.: ${item.assigneeUserId}' : ''}',

          ),

          isThreeLine: true,

          trailing: canWrite

              ? Wrap(

                  spacing: 8,

                  crossAxisAlignment: WrapCrossAlignment.center,

                  children: [

                    if (_canShowHistory(item))

                      IconButton(

                        tooltip: 'История',

                        onPressed: () => _showHistory(item),

                        icon: const Icon(Icons.history_rounded),

                      ),

                    if (_canActOn(item))

                      FilledButton(

                        onPressed: () => _moderateUnified(item),

                        child: const Text('Решить'),

                      ),

                  ],

                )

              : null,

        );

      },

    );

  }



  Widget _buildLegacyList(bool canWrite) {

    if (_legacyItems.isEmpty) {

      return const Center(child: Text('Очередь пуста'));

    }

    return ListView.separated(

      itemCount: _legacyItems.length,

      separatorBuilder: (_, __) => const Divider(height: 1),

      itemBuilder: (context, index) {

        final item = _legacyItems[index];

        return ListTile(

          title: Text(

            '${item.entityType.labelRu} · reports=${item.openReports}',

          ),

          subtitle: Text(

            'tags=${item.tagScores}\n'

            'text=${item.bodyText ?? '—'}',

          ),

          isThreeLine: true,

          trailing: canWrite

              ? Wrap(

                  spacing: 8,

                  children: [

                    TextButton(

                      onPressed: () => _moderateLegacy(item.reviewId, 'hide'),

                      child: const Text('Скрыть'),

                    ),

                    TextButton(

                      onPressed: () =>

                          _moderateLegacy(item.reviewId, 'restore'),

                      child: const Text('Восстановить'),

                    ),

                  ],

                )

              : null,

        );

      },

    );

  }

}

