import 'package:flutter/material.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import 'terms_models.dart';
import 'terms_repository.dart';

class TermsScreen extends StatefulWidget {
  const TermsScreen({super.key, required this.session, this.repository});

  final AdminSessionController session;
  final TermsRepository? repository;

  @override
  State<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends State<TermsScreen> {
  late final TermsRepository _repository =
      widget.repository ??
      (AdminBackendConfig.isDemoMode
          ? LocalTermsRepository()
          : SupabaseTermsRepository());

  List<AcademicTermView> _terms = const [];
  final Map<String, TermReadiness> _readiness = {};
  bool _loading = true;
  String? _busyTermId;

  bool get _canManage =>
      widget.session.isLocalPrototype ||
      widget.session.capabilities.canManageTerms;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final terms = await _repository.listTerms();
      final readinessEntries = <String, TermReadiness>{};
      for (final term in terms) {
        readinessEntries[term.id] = await _repository.readiness(
          termId: term.id,
        );
      }
      _terms = terms;
      _readiness
        ..clear()
        ..addAll(readinessEntries);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatDate(DateTime? value) {
    if (value == null) return '—';
    final d = value.toLocal();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }

  Future<void> _checkReadiness(AcademicTermView term) async {
    setState(() => _busyTermId = term.id);
    try {
      final readiness = await _repository.readiness(termId: term.id);
      _readiness[term.id] = readiness;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Готовность · ${term.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Готовность: ${readiness.readinessPercent}%'),
              Text('Групп: ${readiness.groupsCount}'),
              Text('Предметов: ${readiness.subjectsCount}'),
              Text('Предметных чатов: ${readiness.subjectChatsCount}'),
              Text('Не хватает предметов: ${readiness.missingSubjects}'),
              Text(
                'Не хватает предметных чатов: ${readiness.missingSubjectChats}',
              ),
              if (readiness.notification != null) ...[
                const SizedBox(height: 8),
                Text(readiness.notification!),
              ],
              if (readiness.blockers.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Проблемы:'),
                for (final blocker in readiness.blockers) Text('• $blocker'),
              ],
              const SizedBox(height: 8),
              const Text('Автоматическое переключение выключено.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busyTermId = null);
    }
  }

  Future<void> _createMissing(AcademicTermView term) async {
    setState(() => _busyTermId = term.id);
    try {
      final dry = await _repository.backfillDryRun(term.id);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Создать недостающее · ${term.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Будет добавлено предметов: ${dry['missing_subjects'] ?? 0}',
              ),
              Text(
                'Будет создано предметных чатов: ${dry['missing_subject_chats'] ?? 0}',
              ),
              const SizedBox(height: 8),
              const Text('Текущий семестр и действующие чаты не изменятся'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Создать недостающее'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final result = await _repository.backfill(term.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['idempotent_replay'] == true
                ? 'Недостающее уже создано ранее'
                : 'Добавлено предметов: ${result['created_subjects'] ?? 0}, '
                      'предметных чатов: ${result['created_subject_chats'] ?? 0}',
          ),
        ),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _busyTermId = null);
    }
  }

  Future<void> _startNext(AcademicTermView term) async {
    setState(() => _busyTermId = term.id);
    try {
      final preview = await _repository.startNextDryRun(term.id);
      if (!mounted) return;
      if (!preview.ok && !preview.idempotentReplay) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Переход недоступен'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final blocker in preview.blockers) Text('• $blocker'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        );
        return;
      }

      final confirmController = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('Начать новый семестр'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Текущий семестр: ${preview.currentTermName}'),
                  Text('Новый семестр: ${preview.newTermName}'),
                  const SizedBox(height: 12),
                  Text(
                    'Будет архивировано предметных чатов: ${preview.archivableSubjectChats}',
                  ),
                  Text(
                    'Будет создано предметов: ${preview.willCreateSubjects}',
                  ),
                  Text(
                    'Будет создано предметных чатов: ${preview.willCreateSubjectChats}',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Расписание и учебный контекст переключатся на новый семестр.',
                  ),
                  const Text('Постоянный чат учебной группы сохранится.'),
                  const SizedBox(height: 16),
                  Text(
                    'Для подтверждения введите полное название: ${preview.confirmNameRequired}',
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmController,
                    onChanged: (_) => setLocal(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Название нового семестра',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed:
                    confirmController.text.trim() == preview.confirmNameRequired
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Начать новый семестр'),
              ),
            ],
          ),
        ),
      );
      confirmController.dispose();
      if (confirmed != true) return;

      final result = await _repository.startNext(
        termId: term.id,
        confirmName: preview.confirmNameRequired,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['idempotent_replay'] == true
                ? 'Семестр уже активен'
                : 'Новый семестр начат. Архивировано предметных чатов: ${result['archived_subject_chats'] ?? 0}',
          ),
        ),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _busyTermId = null);
    }
  }

  List<AcademicTermView> _section(String lifecycle) =>
      _terms.where((t) => t.lifecycle == lifecycle).toList(growable: false);

  Widget _termCard(AcademicTermView term) {
    final readiness = _readiness[term.id];
    final busy = _busyTermId == term.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    term.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Chip(
                  label: Text(term.isCurrent ? 'Текущий' : term.lifecycleLabel),
                  backgroundColor: term.isCurrent
                      ? const Color(0xFFDCFCE7)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Даты: ${_formatDate(term.startsOn)} — ${_formatDate(term.endsOn)}',
            ),
            if (term.yearName != null) Text('Учебный год: ${term.yearName}'),
            if (readiness != null) ...[
              const SizedBox(height: 8),
              Text('Готовность: ${readiness.readinessPercent}%'),
              Text('Групп: ${readiness.groupsCount}'),
              Text('Предметов: ${readiness.subjectsCount}'),
              Text('Предметных чатов: ${readiness.subjectChatsCount}'),
              if (readiness.missingSubjects > 0 ||
                  readiness.missingSubjectChats > 0)
                Text(
                  'Проблемы: не хватает ${readiness.missingSubjects} предметов и ${readiness.missingSubjectChats} предметных чатов',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (readiness.notification != null && term.isNearestNext)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(readiness.notification!),
                ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_canManage)
                  OutlinedButton(
                    onPressed: busy ? null : () => _checkReadiness(term),
                    child: const Text('Проверить готовность'),
                  ),
                if (_canManage)
                  FilledButton.tonal(
                    onPressed: busy ? null : () => _createMissing(term),
                    child: const Text('Создать недостающее'),
                  ),
                if (_canManage && term.isNearestNext)
                  FilledButton(
                    onPressed: busy ? null : () => _startNext(term),
                    child: const Text('Начать новый семестр'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionBlock(String title, List<AcademicTermView> terms) {
    if (terms.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        for (final term in terms) _termCard(term),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_canManage && !widget.session.isLocalPrototype) {
      return const Center(
        child: Text('Недостаточно прав для управления учебными периодами'),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final nearest = _terms.where((t) => t.isNearestNext).toList();
    final banner = nearest.isNotEmpty ? _readiness[nearest.first.id] : null;
    return ListView(
      children: [
        Text(
          'Учебные периоды',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Подготовка данных отделена от запуска нового семестра. Автоматическое переключение выключено.',
        ),
        if (banner?.notification != null) ...[
          const SizedBox(height: 12),
          Material(
            color: const Color(0xFFFFF7ED),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active_outlined),
                  const SizedBox(width: 10),
                  Expanded(child: Text(banner!.notification!)),
                  TextButton(
                    onPressed: () => _checkReadiness(nearest.first),
                    child: const Text('Проверить готовность'),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _sectionBlock('Текущий семестр', _section('active')),
        _sectionBlock('Будущие семестры', _section('planned')),
        _sectionBlock('Завершённые семестры', _section('completed')),
      ],
    );
  }
}
