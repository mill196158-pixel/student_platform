import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/admin_backend_config.dart';
import '../../core/auth/admin_session_controller.dart';
import 'academic_process_calendar_review_panel.dart';
import 'group_recognition_panel.dart';
import 'import_studio_file_save.dart';
import 'import_studio_item.dart';
import 'import_studio_mapping.dart';
import 'import_studio_repository.dart';
import 'import_studio_template_service.dart';
import 'import_studio_workbook_service.dart';
import 'curriculum_document_review_panel.dart';
import 'supabase_import_studio_repository.dart';

/// Stage 19 Import Studio hub — XLSX template → upload → mapping → preview → dry-run.
class ImportStudioScreen extends StatefulWidget {
  const ImportStudioScreen({
    super.key,
    this.repository,
    this.session,
    this.curriculumPanelBuilder,
    this.groupPanelBuilder,
    this.calendarPanelBuilder,
  });

  final ImportStudioRepository? repository;
  final AdminSessionController? session;
  final WidgetBuilder? curriculumPanelBuilder;
  final WidgetBuilder? groupPanelBuilder;
  final WidgetBuilder? calendarPanelBuilder;

  @override
  State<ImportStudioScreen> createState() => _ImportStudioScreenState();
}

class _ImportStudioScreenState extends State<ImportStudioScreen> {
  late final ImportStudioRepository _repository =
      widget.repository ?? _defaultRepo();

  ImportStudioWorkflowStep _step = ImportStudioWorkflowStep.hub;
  List<ImportStudioDomainInfo> _domains = [];
  ImportStudioDomainInfo? _selectedDomain;
  ImportStudioBatch? _batch;
  ImportStudioDiff? _diff;
  bool _loading = true;
  bool _busy = false;
  String? _banner;
  String? _loadError;
  final _batchKeyController = TextEditingController();

  bool get _isLocal =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      AdminBackendConfig.isDemoMode;

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  ImportStudioRepository _defaultRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalImportStudioRepository();
    final client = _tryClient();
    if (client == null) return LocalImportStudioRepository();
    return SupabaseImportStudioRepository(client: client);
  }

  @override
  void initState() {
    super.initState();
    _reloadDomains();
  }

  @override
  void dispose() {
    _batchKeyController.dispose();
    super.dispose();
  }

  Future<void> _reloadDomains() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final domains = await _repository.listDomains();
      if (!mounted) return;
      setState(() {
        _domains = domains;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  void _selectDomain(ImportStudioDomainInfo domain) {
    if (!domain.canDryRun) {
      setState(() {
        _banner = domain.notes;
      });
      return;
    }
    setState(() {
      _selectedDomain = domain;
      _step = ImportStudioWorkflowStep.template;
      _batch = null;
      _diff = null;
      _banner = null;
      _batchKeyController.clear();
    });
  }

  Future<void> _runDryRun({
    required List<Map<String, dynamic>> rows,
    required String fileName,
  }) async {
    final domain = _selectedDomain;
    if (domain == null) return;

    if (rows.isEmpty) {
      setState(() => _banner = 'Нужна хотя бы одна строка для dry-run.');
      return;
    }

    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      final batch = await _repository.startDryRun(
        domain: domain.domain,
        rows: rows,
        fileName: fileName,
        batchKey: _batchKeyController.text.trim().isEmpty
            ? null
            : _batchKeyController.text.trim(),
      );
      final diff = await _repository.getDiff(batchId: batch.batchId);
      if (!mounted) return;
      setState(() {
        _batch = batch;
        _diff = diff;
        _step = ImportStudioWorkflowStep.diff;
        _batchKeyController.text = batch.batchKey;
        _banner = batch.alreadyApplied
            ? 'Batch уже был применён ранее (idempotent replay).'
            : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmApply() async {
    final batch = _batch;
    if (batch == null) return;

    if (!batch.supportsApply) {
      setState(() {
        _banner =
            'Домен ${importStudioDomainLabel(batch.domain)} — validate-only. Apply недоступен.';
        _step = ImportStudioWorkflowStep.applied;
      });
      return;
    }

    final confirmKey = _batchKeyController.text.trim();
    if (confirmKey != batch.batchKey) {
      setState(() {
        _banner = 'Введите точный batch_key для подтверждения apply.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      final applied = await _repository.apply(
        batchId: batch.batchId,
        confirmBatchKey: confirmKey,
      );
      if (!mounted) return;
      if (applied.status == ImportStudioBatchStatus.failed) {
        setState(() {
          _batch = applied;
          _step = ImportStudioWorkflowStep.diff;
          _banner =
              'Apply отклонён: delegated import вернул ошибки. '
              'Batch ${applied.batchId} в статусе failed.';
        });
        return;
      }
      setState(() {
        _batch = applied;
        _step = ImportStudioWorkflowStep.applied;
        _banner = applied.idempotentReplay
            ? 'Idempotent replay: batch уже был applied.'
            : 'Batch применён. ID: ${applied.batchId}';
      });
    } on ImportStudioRepositoryException catch (error) {
      if (!mounted) return;
      if (error.code == 'delegated_apply_failed') {
        ImportStudioBatch? failedBatch = _batch;
        try {
          final batches = await _repository.listBatches(domain: batch.domain);
          for (final item in batches) {
            if (item.batchId == batch.batchId) {
              failedBatch = item;
              break;
            }
          }
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _batch = failedBatch;
          _step = ImportStudioWorkflowStep.diff;
          _banner = error.message;
        });
        return;
      }
      setState(() => _banner = error.toString());
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _resetToHub() {
    setState(() {
      _step = ImportStudioWorkflowStep.hub;
      _selectedDomain = null;
      _batch = null;
      _diff = null;
      _banner = null;
      _batchKeyController.clear();
    });
  }

  void _selectDomainByName(String domainName) {
    for (final domain in _domains) {
      if (domain.domain == domainName) {
        _selectDomain(domain);
        return;
      }
    }
    setState(() {
      _banner = 'Импорт «${importStudioDomainLabel(domainName)}» недоступен.';
    });
  }

  Future<void> _openCurriculumReview() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1180,
          height: 820,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child:
                widget.curriculumPanelBuilder?.call(context) ??
                CurriculumDocumentReviewPanel(),
          ),
        ),
      ),
    );
  }

  Future<void> _openGroupRecognition() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1120,
          height: 780,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child:
                widget.groupPanelBuilder?.call(context) ??
                const GroupRecognitionPanel(),
          ),
        ),
      ),
    );
  }

  Future<void> _openAcademicProcessCalendarReview() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1240,
          height: 860,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child:
                widget.calendarPanelBuilder?.call(context) ??
                const AcademicProcessCalendarReviewPanel(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return _ErrorPanel(message: _loadError!, onRetry: _reloadDomains);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          isLocal: _isLocal,
          step: _step,
          onBack: _step == ImportStudioWorkflowStep.hub ? null : _resetToHub,
        ),
        if (_banner != null) ...[
          const SizedBox(height: 12),
          MaterialBanner(
            content: Text(_banner!),
            backgroundColor: const Color(0xFFFFF3E0),
            actions: [
              TextButton(
                onPressed: () => setState(() => _banner = null),
                child: const Text('OK'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case ImportStudioWorkflowStep.hub:
        return _DomainHub(
          domains: _domains,
          onSelect: _selectDomain,
          onOpenCurriculum: _openCurriculumReview,
          onOpenGroups: _openGroupRecognition,
          onOpenCalendar: _openAcademicProcessCalendarReview,
          onOpenStudents: () => _selectDomainByName('students'),
        );
      case ImportStudioWorkflowStep.template:
        return _ImportSourceStep(
          domain: _selectedDomain!,
          batchKeyController: _batchKeyController,
          busy: _busy,
          onDryRun: _runDryRun,
          onBack: _resetToHub,
          onError: (message) => setState(() => _banner = message),
        );
      case ImportStudioWorkflowStep.dryRun:
      case ImportStudioWorkflowStep.diff:
        return _DiffStep(
          domain: _selectedDomain!,
          batch: _batch!,
          diff: _diff,
          batchKeyController: _batchKeyController,
          busy: _busy,
          onConfirm: () =>
              setState(() => _step = ImportStudioWorkflowStep.confirm),
          onBack: () =>
              setState(() => _step = ImportStudioWorkflowStep.template),
        );
      case ImportStudioWorkflowStep.confirm:
        return _ConfirmStep(
          batch: _batch!,
          batchKeyController: _batchKeyController,
          busy: _busy,
          onApply: _confirmApply,
          onBack: () => setState(() => _step = ImportStudioWorkflowStep.diff),
        );
      case ImportStudioWorkflowStep.applied:
        return _AppliedStep(
          batch: _batch!,
          busy: _busy,
          onRestart: _resetToHub,
          onRollback: _rollbackBatch,
        );
    }
  }

  Future<void> _rollbackBatch() async {
    final batch = _batch;
    if (batch == null) return;

    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      final result = await _repository.rollbackBatch(
        batchId: batch.batchId,
        confirmBatchKey: batch.batchKey,
      );
      if (!mounted) return;
      setState(() {
        _banner = result.message;
        if (result.ok) {
          _batch = ImportStudioBatch(
            batchId: batch.batchId,
            domain: batch.domain,
            status: ImportStudioBatchStatus.rolledBack,
            batchKey: batch.batchKey,
            fileName: batch.fileName,
            rowCount: batch.rowCount,
            errorCount: batch.errorCount,
            summary: batch.summary,
            domainState: batch.domainState,
            supportsApply: batch.supportsApply,
            alreadyApplied: batch.alreadyApplied,
            idempotentReplay: batch.idempotentReplay,
            rollbackSafe: batch.rollbackSafe,
          );
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.isLocal, required this.step, this.onBack});

  final bool isLocal;
  final ImportStudioWorkflowStep step;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null)
          IconButton(
            tooltip: 'К Import Studio',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import Studio',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              Text(
                isLocal
                    ? 'Локальный scaffold: XLSX → mapping → dry-run → confirm'
                    : 'RPC через Supabase (без service_role)',
                style: const TextStyle(color: Colors.black54),
              ),
            ],
          ),
        ),
        Chip(
          avatar: Icon(
            isLocal ? Icons.science_outlined : Icons.cloud_outlined,
            size: 18,
          ),
          label: Text(_stepLabel(step)),
        ),
      ],
    );
  }

  String _stepLabel(ImportStudioWorkflowStep step) {
    switch (step) {
      case ImportStudioWorkflowStep.hub:
        return 'Домены';
      case ImportStudioWorkflowStep.template:
        return 'Файл';
      case ImportStudioWorkflowStep.dryRun:
        return 'Dry-run';
      case ImportStudioWorkflowStep.diff:
        return 'Diff';
      case ImportStudioWorkflowStep.confirm:
        return 'Confirm';
      case ImportStudioWorkflowStep.applied:
        return 'Applied';
    }
  }
}

class _DomainHub extends StatelessWidget {
  const _DomainHub({
    required this.domains,
    required this.onSelect,
    required this.onOpenCurriculum,
    required this.onOpenGroups,
    required this.onOpenCalendar,
    required this.onOpenStudents,
  });

  final List<ImportStudioDomainInfo> domains;
  final ValueChanged<ImportStudioDomainInfo> onSelect;
  final VoidCallback onOpenCurriculum;
  final VoidCallback onOpenGroups;
  final VoidCallback onOpenCalendar;
  final VoidCallback onOpenStudents;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Академическая цепочка',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Проходите этапы слева направо: что изучают → кто учится → '
            'когда идут периоды → когда стоят конкретные пары.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 16),
          _AcademicChainCard(
            step: 1,
            icon: Icons.account_tree_outlined,
            title: 'Учебный план',
            status: 'Review + server preview',
            statusColor: const Color(0xFF3157C8),
            description:
                'Загрузите PDF или XLSX, проверьте предметы, семестры, часы '
                'и формы контроля. Здесь же выбираются программа, форма '
                'обучения и год поступления.',
            primaryLabel: 'Открыть проверку плана',
            onPrimary: onOpenCurriculum,
            footer:
                'PDF/XLSX принимаются специализированной проверкой; сохранение '
                'возможно только после server preview и подтверждения.',
          ),
          const _ChainConnector(),
          _AcademicChainCard(
            step: 2,
            icon: Icons.groups_outlined,
            title: 'Группы и студенты',
            status: 'Matching preview',
            statusColor: Color(0xFF8B5A00),
            description:
                'Группа появляется из студента или позже из расписания. '
                'Слева параллель, справа курс; сервер считает год поступления. '
                'Зачётка обычно начинается с этого года; редкий перевод на '
                '2 курс нельзя смешать с другой группой того же названия.',
            primaryLabel: 'Проверить группы и дубли',
            onPrimary: onOpenGroups,
            secondaryLabel: 'Existing students XLSX',
            onSecondary: onOpenStudents,
            footer:
                'Студенческий XLSX обновляет существующих Auth-пользователей '
                'и не создаёт аккаунты. Нужен учебный год: одинаковые названия '
                'разных лет поступления не сливаются.',
          ),
          const _ChainConnector(),
          _AcademicChainCard(
            step: 3,
            icon: Icons.date_range_outlined,
            title: 'График учебного процесса',
            status: 'Review + server preview',
            statusColor: Color(0xFF3157C8),
            description:
                'Загрузите официальный PDF или изображение и вручную проверьте '
                'периоды занятий, сессии, практики и ГИА для учебного года.',
            primaryLabel: 'Открыть годовой график',
            onPrimary: onOpenCalendar,
            footer:
                'Это годовой график с периодами. Он не меняет глобальные '
                'academic_terms и не переключает текущий семестр.',
          ),
          const _ChainConnector(),
          const _AcademicChainCard(
            step: 4,
            icon: Icons.event_busy_outlined,
            title: 'Расписание и готовность',
            status: 'Не реализовано',
            statusColor: Color(0xFF6B7280),
            description:
                'Будущий этап проверит даты пар и экзаменов по опубликованному '
                'графику и покажет конфликты до сохранения.',
            primaryLabel: 'Проверка расписания недоступна',
            footer:
                'Валидация и apply расписания отсутствуют. Текущий семестр, '
                'offering, команды и чаты здесь не создаются.',
          ),
          const SizedBox(height: 20),
          const _AcademicReadinessStrip(),
          const SizedBox(height: 28),
          const Text(
            'Расширенные импорты XLSX',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Все прежние домены сохранены. Это структурированные XLSX-потоки '
            'с dry-run/diff/apply. PDF и изображения используйте только в '
            'специализированных проверках плана и годового графика выше.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          for (final domain in domains) ...[
            Card(
              child: ListTile(
                leading: Icon(_domainIcon(domain.domain)),
                title: Text(domain.label),
                subtitle: Text(
                  '${_advancedDomainHint(domain.domain)}\n'
                  '${importStudioDomainStateLabel(domain.domainState)} · '
                  '${domain.applyPermission}',
                ),
                isThreeLine: true,
                trailing: domain.canDryRun
                    ? const Icon(Icons.chevron_right_rounded)
                    : const Chip(label: Text('Скоро')),
                onTap: domain.canDryRun ? () => onSelect(domain) : null,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  String _advancedDomainHint(String domain) {
    return switch (domain) {
      'students' =>
        'Только существующие Auth-пользователи; аккаунты не создаёт',
      'terms' => 'Глобальные семестры; не годовой график учебного процесса',
      'curriculum' => 'Legacy structured XLSX; PDF открывайте в шаге 1',
      'groups' =>
        'Legacy XLSX apply; распознавание названий открывайте в шаге 2',
      _ => 'Структурированный XLSX import',
    };
  }

  IconData _domainIcon(String domain) {
    switch (domain) {
      case 'teachers':
        return Icons.school_outlined;
      case 'subjects':
        return Icons.menu_book_outlined;
      case 'students':
        return Icons.groups_outlined;
      case 'groups':
        return Icons.group_work_outlined;
      case 'curriculum':
        return Icons.account_tree_outlined;
      case 'terms':
        return Icons.calendar_month_outlined;
      case 'offerings':
        return Icons.assignment_outlined;
      case 'teacher_links':
        return Icons.link_outlined;
      case 'enrollments':
        return Icons.how_to_reg_outlined;
      default:
        return Icons.upload_file_outlined;
    }
  }
}

class _AcademicChainCard extends StatelessWidget {
  const _AcademicChainCard({
    required this.step,
    required this.icon,
    required this.title,
    required this.status,
    required this.statusColor,
    required this.description,
    required this.primaryLabel,
    required this.footer,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final int step;
  final IconData icon;
  final String title;
  final String status;
  final Color statusColor;
  final String description;
  final String primaryLabel;
  final String footer;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final enabled = onPrimary != null;
    return Card(
      elevation: 0,
      color: enabled ? const Color(0xFFF8F9FD) : const Color(0xFFF4F4F5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: enabled ? const Color(0xFFD9DDEC) : const Color(0xFFE1E1E3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: enabled
                  ? const Color(0xFFE5E9FA)
                  : const Color(0xFFE5E7EB),
              child: Text(
                '$step',
                style: TextStyle(
                  color: enabled ? const Color(0xFF3157C8) : Colors.black45,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 20),
                          const SizedBox(width: 7),
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      Chip(
                        side: BorderSide(
                          color: statusColor.withValues(alpha: .3),
                        ),
                        backgroundColor: statusColor.withValues(alpha: .08),
                        label: Text(
                          status,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(description),
                  const SizedBox(height: 8),
                  Text(
                    footer,
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: onPrimary,
                        icon: Icon(
                          enabled
                              ? Icons.open_in_new_rounded
                              : Icons.lock_outline_rounded,
                        ),
                        label: Text(primaryLabel),
                      ),
                      if (secondaryLabel != null)
                        OutlinedButton(
                          onPressed: onSecondary,
                          child: Text(secondaryLabel!),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChainConnector extends StatelessWidget {
  const _ChainConnector();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 39),
      child: SizedBox(
        height: 22,
        child: Align(
          alignment: Alignment.centerLeft,
          child: VerticalDivider(width: 2, thickness: 2),
        ),
      ),
    );
  }
}

class _AcademicReadinessStrip extends StatelessWidget {
  const _AcademicReadinessStrip();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF8E7),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.verified_user_outlined, color: Color(0xFF8B5A00)),
                SizedBox(width: 8),
                Text(
                  'Готовность цепочки',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                Chip(label: Text('План: review доступен')),
                Chip(label: Text('Группы: preview доступен')),
                Chip(label: Text('Календарь: review доступен')),
                Chip(label: Text('Расписание: не готово')),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Проверка документов не переключает текущий семестр и не '
              'создаёт предметные offering, команды или чаты.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportSourceStep extends StatefulWidget {
  const _ImportSourceStep({
    required this.domain,
    required this.batchKeyController,
    required this.busy,
    required this.onDryRun,
    required this.onBack,
    required this.onError,
  });

  final ImportStudioDomainInfo domain;
  final TextEditingController batchKeyController;
  final bool busy;
  final Future<void> Function({
    required List<Map<String, dynamic>> rows,
    required String fileName,
  })
  onDryRun;
  final VoidCallback onBack;
  final ValueChanged<String> onError;

  @override
  State<_ImportSourceStep> createState() => _ImportSourceStepState();
}

class _ImportSourceStepState extends State<_ImportSourceStep> {
  final _workbookService = ImportStudioWorkbookService();
  final _templateService = ImportStudioTemplateService();
  final _sampleRowsController = TextEditingController();

  String? _fileName;
  List<Map<String, dynamic>> _previewRows = const [];
  bool _useDemoSample = false;

  @override
  void initState() {
    super.initState();
    _sampleRowsController.text = _defaultSampleCsv(widget.domain.domain);
  }

  @override
  void dispose() {
    _sampleRowsController.dispose();
    super.dispose();
  }

  String _defaultSampleCsv(String domain) {
    final columns = importStudioTemplateColumns[domain] ?? const [];
    if (columns.isEmpty) return '';
    final header = columns.join(',');
    final sample = switch (domain) {
      'teachers' => 'Иванов Иван,ivan@example.edu,ИТ,доцент,к.т.н.,',
      'subjects' => 'Математика,Описание,ИТ,экзамен,,',
      'students' => 'student01,Иван,Иванов,ИТ-101',
      'groups' => ',ИТ-101',
      'curriculum' => ',ИТ-101,Математика,1,4,144,экзамен,,',
      'terms' => ',2025/2026,Осенний,1,2025-09-01,2026-01-31',
      'offerings' => ',ИТ-101,Математика,2025/2026,Осенний,1,,active',
      'teacher_links' =>
        ',,ИТ-101,Математика,2025/2026,Осенний,,Иванов Иван Иванович,lecturer',
      'enrollments' => ',student01,ИТ-101,2026-02-01',
      _ => List.filled(columns.length, '').join(','),
    };
    return '$header\n$sample';
  }

  Future<void> _downloadTemplate() async {
    try {
      final bytes = _templateService.buildTemplateBytes(widget.domain.domain);
      final saved = await saveImportStudioTemplateBytes(
        bytes: bytes,
        fileName: _templateService.suggestedFileName(widget.domain.domain),
      );
      if (!mounted) return;
      if (saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Шаблон сохранён')));
      }
    } catch (error) {
      widget.onError('Не удалось создать шаблон: $error');
    }
  }

  Future<void> _pickXlsx() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    final bytes = picked.files.first.bytes;
    final fileName = picked.files.first.name;
    if (bytes == null) {
      widget.onError('Не удалось прочитать файл.');
      return;
    }

    try {
      final workbook = _workbookService.readWorkbook(bytes);
      if (!mounted) return;

      var sheet = workbook.sheets.first;
      if (workbook.sheets.length > 1) {
        final selected = await showDialog<ImportStudioSheet>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Выберите лист'),
            children: [
              for (final candidate in workbook.sheets)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, candidate),
                  child: Text(
                    '${candidate.name} (${candidate.rows.length} строк)',
                  ),
                ),
            ],
          ),
        );
        if (selected == null) return;
        sheet = selected;
      }

      var mapping = suggestImportStudioHeaderMapping(
        widget.domain.domain,
        sheet.headers,
      );
      if (!mounted) return;

      final confirmed = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => _MappingDialog(
          domain: widget.domain.domain,
          headers: sheet.headers,
          initial: mapping,
          fileName: fileName,
        ),
      );
      if (confirmed == null) return;

      setState(() {
        _useDemoSample = false;
        _fileName = fileName;
        _previewRows = mapImportStudioRows(
          domain: widget.domain.domain,
          rawRows: sheet.rows,
          fieldToHeader: confirmed,
        );
      });
    } catch (error) {
      widget.onError('Импорт XLSX: $error');
    }
  }

  Future<void> _openCurriculumDocumentReview() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1180,
          height: 820,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: CurriculumDocumentReviewPanel(),
          ),
        ),
      ),
    );
  }

  Future<void> _openAcademicProcessCalendarReview() async {
    await showDialog<void>(
      context: context,
      builder: (context) => const Dialog(
        insetPadding: EdgeInsets.all(24),
        child: SizedBox(
          width: 1240,
          height: 860,
          child: Padding(
            padding: EdgeInsets.all(20),
            child: AcademicProcessCalendarReviewPanel(),
          ),
        ),
      ),
    );
  }

  Future<void> _openGroupRecognition() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 1120,
          height: 780,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: GroupRecognitionPanel(
              initialRows: _previewRows,
              fileName: _fileName ?? 'groups.xlsx',
            ),
          ),
        ),
      ),
    );
  }

  void _loadDemoSample() {
    final rows = parseImportStudioSampleCsv(
      widget.domain.domain,
      _sampleRowsController.text,
    );
    setState(() {
      _useDemoSample = true;
      _fileName = 'demo-sample.csv';
      _previewRows = rows;
    });
  }

  Future<void> _startDryRun() async {
    if (_previewRows.isEmpty) {
      widget.onError('Загрузите XLSX или подготовьте demo/sample строки.');
      return;
    }
    await widget.onDryRun(
      rows: _previewRows,
      fileName: _fileName ?? 'import.xlsx',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.domain.label,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          widget.domain.notes,
          style: const TextStyle(color: Colors.black54),
        ),
        if (widget.domain.domain == 'students') ...[
          const SizedBox(height: 8),
          const _DomainSafetyNotice(
            icon: Icons.person_search_outlined,
            text:
                'Этот XLSX-поток только обновляет существующих '
                'Auth-пользователей. Новые аккаунты здесь не создаются. '
                'Группа из студента появляется только с выбранным учебным '
                'годом: зачётка обычно подтверждает год поступления, а '
                'редкий перевод на 2 курс не смешивается автоматически.',
          ),
        ],
        if (widget.domain.domain == 'terms') ...[
          const SizedBox(height: 8),
          const _DomainSafetyNotice(
            icon: Icons.info_outline,
            text:
                'Это глобальные academic_terms. Годовой график занятий, '
                'сессии и ГИА открывается отдельной кнопкой ниже.',
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: widget.busy ? null : _downloadTemplate,
              icon: const Icon(Icons.download_outlined),
              label: const Text('Скачать шаблон XLSX'),
            ),
            FilledButton.icon(
              onPressed: widget.busy ? null : _pickXlsx,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Загрузить XLSX'),
            ),
            if (widget.domain.domain == 'curriculum')
              FilledButton.tonalIcon(
                onPressed: widget.busy ? null : _openCurriculumDocumentReview,
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Распознать план PDF / XLSX'),
              ),
            if (widget.domain.domain == 'terms')
              FilledButton.tonalIcon(
                onPressed: widget.busy
                    ? null
                    : _openAcademicProcessCalendarReview,
                icon: const Icon(Icons.date_range_outlined),
                label: const Text('График учебного процесса'),
              ),
            if (widget.domain.domain == 'groups')
              FilledButton.tonalIcon(
                onPressed: widget.busy ? null : _openGroupRecognition,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Проверить названия и дубли'),
              ),
          ],
        ),
        if (_fileName != null) ...[
          const SizedBox(height: 12),
          Text(
            _useDemoSample
                ? 'Demo/sample: $_fileName'
                : 'Файл: $_fileName · строк: ${_previewRows.length}',
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: widget.batchKeyController,
          decoration: const InputDecoration(
            labelText: 'batch_key (опционально, для idempotency)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _previewRows.isEmpty
              ? Center(
                  child: Text(
                    'Загрузите XLSX и сопоставьте колонки,\n'
                    'или используйте demo/sample ниже.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                )
              : _MappedPreviewTable(rows: _previewRows),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          title: const Text('Demo / sample CSV (fallback)'),
          subtitle: const Text('Только для локальной проверки без файла'),
          children: [
            SizedBox(
              height: 120,
              child: TextField(
                controller: _sampleRowsController,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'Заголовок + строки (wire-имена колонок)',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.busy ? null : _loadDemoSample,
                child: const Text('Подготовить preview из sample'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              onPressed: widget.busy ? null : widget.onBack,
              child: const Text('Назад'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: widget.busy || _previewRows.isEmpty
                  ? null
                  : _startDryRun,
              icon: widget.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Dry-run'),
            ),
          ],
        ),
      ],
    );
  }
}

class _DomainSafetyNotice extends StatelessWidget {
  const _DomainSafetyNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8D7A9)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(icon, size: 19, color: const Color(0xFF8B5A00)),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _MappedPreviewTable extends StatelessWidget {
  const _MappedPreviewTable({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final preview = rows.take(20).toList();
    final keys = preview.isEmpty
        ? const <String>[]
        : preview.first.keys.toList();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Preview mapped rows (${rows.length} всего, показаны ${preview.length})',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [for (final key in keys) DataColumn(label: Text(key))],
                rows: [
                  for (final row in preview)
                    DataRow(
                      cells: [
                        for (final key in keys)
                          DataCell(Text(_cellText(row[key]))),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _cellText(dynamic value) {
    if (value is Map || value is List) return value.toString();
    return '${value ?? ''}';
  }
}

class _MappingDialog extends StatefulWidget {
  const _MappingDialog({
    required this.domain,
    required this.headers,
    required this.initial,
    required this.fileName,
  });

  final String domain;
  final List<String> headers;
  final Map<String, String> initial;
  final String fileName;

  @override
  State<_MappingDialog> createState() => _MappingDialogState();
}

class _MappingDialogState extends State<_MappingDialog> {
  late Map<String, String?> _mapping;
  late final Map<String, String> _fields;

  @override
  void initState() {
    super.initState();
    _fields = importStudioMappingFieldLabels(widget.domain);
    _mapping = {for (final key in _fields.keys) key: widget.initial[key]};
  }

  @override
  Widget build(BuildContext context) {
    final requiredField = importStudioRequiredMappingField(widget.domain);
    return AlertDialog(
      title: Text('Сопоставление колонок · ${widget.fileName}'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: SingleChildScrollView(
          child: Column(
            children: [
              for (final entry in _fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<String?>(
                    initialValue: _mapping[entry.key],
                    decoration: InputDecoration(labelText: entry.value),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('— не использовать —'),
                      ),
                      ...widget.headers.map(
                        (header) => DropdownMenuItem(
                          value: header,
                          child: Text(header),
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _mapping[entry.key] = value),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final result = <String, String>{};
            _mapping.forEach((field, header) {
              if (header != null && header.isNotEmpty) result[field] = header;
            });
            if (requiredField != null && !result.containsKey(requiredField)) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Нужно сопоставить поле «${_fields[requiredField]}».',
                  ),
                ),
              );
              return;
            }
            Navigator.pop(context, result);
          },
          child: const Text('Preview mapped rows'),
        ),
      ],
    );
  }
}

class _DiffStep extends StatelessWidget {
  const _DiffStep({
    required this.domain,
    required this.batch,
    required this.diff,
    required this.batchKeyController,
    required this.busy,
    required this.onConfirm,
    required this.onBack,
  });

  final ImportStudioDomainInfo domain;
  final ImportStudioBatch batch;
  final ImportStudioDiff? diff;
  final TextEditingController batchKeyController;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final summary = batch.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Dry-run: ${domain.label}',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatChip(label: 'Всего', value: '${summary.total}'),
            _StatChip(label: 'Новые', value: '${summary.newCount}'),
            _StatChip(label: 'Обновления', value: '${summary.updateCount}'),
            _StatChip(label: 'Дубликаты', value: '${summary.duplicateCount}'),
            _StatChip(
              label: 'Ошибки',
              value: '${summary.errorCount}',
              isError: summary.hasErrors,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText('batch_id: ${batch.batchId}'),
        SelectableText('batch_key: ${batch.batchKey}'),
        if (summary.hasWarnings) ...[
          const SizedBox(height: 12),
          Card(
            color: const Color(0xFFFFF3E0),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: Colors.orange,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Предупреждения перед apply',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final warning in summary.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('• $warning'),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: diff == null || diff!.rows.isEmpty
              ? const Center(child: Text('Нет строк diff'))
              : ListView.builder(
                  itemCount: diff!.rows.length,
                  itemBuilder: (context, index) {
                    final row = diff!.rows[index];
                    return ListTile(
                      dense: true,
                      leading: _classificationIcon(row.classification),
                      title: Text(
                        'Строка ${row.rowNumber} · ${row.classification.wire}',
                      ),
                      subtitle: Text(
                        row.errorText ??
                            row.mappedPayload.entries
                                .map((e) => '${e.key}=${e.value}')
                                .join(', '),
                      ),
                    );
                  },
                ),
        ),
        Row(
          children: [
            OutlinedButton(
              onPressed: busy ? null : onBack,
              child: const Text('Назад'),
            ),
            const Spacer(),
            if (domain.supportsApply && batch.canConfirmApply)
              FilledButton(
                onPressed: busy ? null : onConfirm,
                child: const Text('Подтвердить apply'),
              )
            else
              FilledButton(
                onPressed: busy ? null : onConfirm,
                child: const Text('Завершить (validate-only)'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _classificationIcon(ImportStudioRowClassification classification) {
    final icon = switch (classification) {
      ImportStudioRowClassification.newRow => Icons.fiber_new_outlined,
      ImportStudioRowClassification.update => Icons.edit_outlined,
      ImportStudioRowClassification.duplicate => Icons.copy_outlined,
      ImportStudioRowClassification.error => Icons.error_outline,
      ImportStudioRowClassification.skip => Icons.skip_next_outlined,
    };
    return Icon(icon, size: 20);
  }
}

class _ConfirmStep extends StatelessWidget {
  const _ConfirmStep({
    required this.batch,
    required this.batchKeyController,
    required this.busy,
    required this.onApply,
    required this.onBack,
  });

  final ImportStudioBatch batch;
  final TextEditingController batchKeyController;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Подтверждение apply',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        const Text(
          'Введите batch_key для подтверждения. Текущий семестр не переключается; '
          'Осень 2026 не создаётся без владельца.',
        ),
        if (batch.summary.hasWarnings) ...[
          const SizedBox(height: 12),
          for (final warning in batch.summary.warnings)
            Text(
              '⚠ $warning',
              style: const TextStyle(color: Colors.deepOrange),
            ),
        ],
        const SizedBox(height: 16),
        SelectableText('batch_id: ${batch.batchId}'),
        const SizedBox(height: 12),
        TextField(
          controller: batchKeyController,
          decoration: const InputDecoration(
            labelText: 'Подтвердите batch_key',
            border: OutlineInputBorder(),
          ),
        ),
        const Spacer(),
        Row(
          children: [
            OutlinedButton(
              onPressed: busy ? null : onBack,
              child: const Text('Назад'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: busy ? null : onApply,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: const Text('Confirm apply'),
            ),
          ],
        ),
      ],
    );
  }
}

class _AppliedStep extends StatelessWidget {
  const _AppliedStep({
    required this.batch,
    required this.busy,
    required this.onRestart,
    required this.onRollback,
  });

  final ImportStudioBatch batch;
  final bool busy;
  final VoidCallback onRestart;
  final VoidCallback onRollback;

  @override
  Widget build(BuildContext context) {
    final isApplied = batch.status == ImportStudioBatchStatus.applied;
    final isRolledBack = batch.status == ImportStudioBatchStatus.rolledBack;
    final canRollback = isApplied && batch.rollbackSafe;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isRolledBack
                  ? Icons.undo_rounded
                  : isApplied
                  ? Icons.check_circle_outline
                  : Icons.info_outline,
              size: 64,
              color: isRolledBack
                  ? Colors.blueGrey
                  : isApplied
                  ? Colors.green
                  : Colors.orange,
            ),
            const SizedBox(height: 16),
            Text(
              isRolledBack
                  ? 'Batch откачен'
                  : isApplied
                  ? 'Batch применён'
                  : 'Dry-run завершён (validate-only)',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SelectableText('batch_id: ${batch.batchId}'),
            SelectableText('batch_key: ${batch.batchKey}'),
            SelectableText('status: ${batch.status.wire}'),
            if (isApplied) ...[
              const SizedBox(height: 8),
              Text(
                batch.rollbackSafe
                    ? 'Откат доступен: только новые записи, без обновлений.'
                    : 'Откат недоступен для домена ${batch.domain}.',
                style: TextStyle(
                  color: batch.rollbackSafe
                      ? Colors.black54
                      : Colors.deepOrange,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.center,
              children: [
                if (canRollback)
                  OutlinedButton.icon(
                    onPressed: busy ? null : onRollback,
                    icon: const Icon(Icons.undo_rounded),
                    label: const Text('Откатить batch'),
                  ),
                FilledButton(
                  onPressed: onRestart,
                  child: const Text('К списку доменов'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    this.isError = false,
  });

  final String label;
  final String value;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        isError ? Icons.warning_amber_rounded : Icons.analytics_outlined,
        size: 16,
        color: isError ? Colors.red : null,
      ),
      label: Text('$label: $value'),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Повторить')),
        ],
      ),
    );
  }
}
