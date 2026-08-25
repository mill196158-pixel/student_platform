import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../../shared/widgets/admin_student_phone_frame.dart';
import '../../academic/students/students_repository.dart';
import '../profile_feed/content_audience_selectors.dart';
import 'supabase_vacancy_repository.dart';
import 'vacancy_item.dart';
import 'vacancy_repository.dart';

/// Admin editor for Stage 17 vacancies domain (dedicated model, not content_items).
class VacancyEditorScreen extends StatefulWidget {
  const VacancyEditorScreen({super.key, this.repository, this.session});

  final VacancyRepository? repository;
  final AdminSessionController? session;

  @override
  State<VacancyEditorScreen> createState() => _VacancyEditorScreenState();
}

class _VacancyEditorScreenState extends State<VacancyEditorScreen> {
  late final VacancyRepository _repository =
      widget.repository ?? _defaultRepo();

  final _titleController = TextEditingController();
  final _companyController = TextEditingController();
  final _summaryController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _locationController = TextEditingController();
  final _salaryController = TextEditingController();
  final _urlController = TextEditingController();
  final _requirementsController = TextEditingController();
  final _contactEmailController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  final _contactTelegramController = TextEditingController();

  List<VacancyItem> _items = [];
  String? _selectedId;
  bool _loading = true;
  bool _busy = false;
  String _audienceMode = 'all';
  String _origin = 'admin';
  VacancyEmploymentType? _employmentType;
  VacancyWorkFormat? _workFormat;
  List<String> _groupIds = const [];
  List<String> _userIds = const [];
  VacancyAudiencePreview? _audiencePreview;
  List<VacancyVersionEntry> _versions = const [];
  List<VacancyModerationEntry> _moderationJournal = const [];
  List<VacancyReportEntry> _openReports = const [];
  DateTime? _expiresAt;
  String? _banner;
  String? _loadError;
  late final StudentsRepository _studentsRepository = _defaultStudentsRepo();

  VacancyItem? get _selected {
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  bool get _canWrite =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canWriteContent;

  bool get _canPublish =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canPublishContent;

  bool get _canModerate =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.can('moderation.action') ||
      widget.session!.capabilities.can('moderation.write');

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  VacancyRepository _defaultRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalVacancyRepository();
    final client = _tryClient();
    if (client == null) return LocalVacancyRepository();
    return SupabaseVacancyRepository(client: client);
  }

  StudentsRepository _defaultStudentsRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalStudentsRepository();
    final client = _tryClient();
    if (client == null) return LocalStudentsRepository();
    return SupabaseStudentsRepository(client: client);
  }

  String _statusRu(VacancyStatus status) {
    switch (status) {
      case VacancyStatus.draft:
        return 'Черновик';
      case VacancyStatus.submitted:
        return 'Отправлена';
      case VacancyStatus.inModeration:
        return 'На модерации';
      case VacancyStatus.approved:
        return 'Одобрена';
      case VacancyStatus.published:
        return 'Опубликована';
      case VacancyStatus.expired:
        return 'Истекла';
      case VacancyStatus.archived:
        return 'В архиве';
      case VacancyStatus.rejected:
        return 'Отклонена';
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
    unawaited(_loadReports());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _companyController.dispose();
    _summaryController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    _salaryController.dispose();
    _urlController.dispose();
    _requirementsController.dispose();
    _contactEmailController.dispose();
    _contactPhoneController.dispose();
    _contactTelegramController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final items = await _repository.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        _selectedId ??= items.isEmpty ? null : items.first.id;
        _loading = false;
      });
      final selected = _selected;
      if (selected != null) {
        _bind(selected);
        unawaited(_loadJournal(selected));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  void _bind(VacancyItem item) {
    _titleController.text = item.title;
    _companyController.text = item.companyName;
    _summaryController.text = item.summary;
    _descriptionController.text = item.descriptionBody;
    _locationController.text = item.location ?? '';
    _salaryController.text = item.salaryText ?? '';
    _urlController.text = item.externalUrl ?? '';
    _requirementsController.text = item.requirementsText;
    _contactEmailController.text = item.contacts['email']?.toString() ?? '';
    _contactPhoneController.text = item.contacts['phone']?.toString() ?? '';
    _contactTelegramController.text =
        item.contacts['telegram']?.toString() ?? '';
    _expiresAt = item.expiresAt;
    _employmentType = item.employmentType;
    _workFormat = item.workFormat;
    _audienceMode = item.audienceMode;
    _origin = switch (item.origin) {
      ContentOrigin.demo => 'demo',
      ContentOrigin.admin => 'admin',
      ContentOrigin.importSource => 'import',
      ContentOrigin.userSubmission => 'user_submission',
    };
    _groupIds = item.audienceGroupIds;
    _userIds = item.audienceUserIds;
    _audiencePreview = null;
    _versions = const [];
    _moderationJournal = const [];
    setState(() {});
  }

  Future<void> _loadJournal(VacancyItem item) async {
    try {
      final versions = await _repository.listVersions(item.id);
      final journal = await _repository.listModerationActions(item.id);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _moderationJournal = journal;
      });
    } catch (_) {}
  }

  Future<void> _loadReports() async {
    try {
      final reports = await _repository.listReports(status: 'open');
      if (!mounted) return;
      setState(() => _openReports = reports);
    } catch (_) {}
  }

  Map<String, dynamic> _contactsFromFields() {
    final contacts = <String, dynamic>{};
    final email = _contactEmailController.text.trim();
    final phone = _contactPhoneController.text.trim();
    final telegram = _contactTelegramController.text.trim();
    if (email.isNotEmpty) contacts['email'] = email;
    if (phone.isNotEmpty) contacts['phone'] = phone;
    if (telegram.isNotEmpty) contacts['telegram'] = telegram;
    return contacts;
  }

  VacancyItem? _draftFromFields({VacancyItem? base}) {
    final title = _titleController.text.trim();
    final summary = _summaryController.text.trim();
    if (title.isEmpty || summary.isEmpty) return null;
    final description = VacancyItem.buildDescription(
      _descriptionController.text.trim(),
      _requirementsController.text.trim(),
    );
    return (base ??
            VacancyItem(
              id: '',
              status: VacancyStatus.draft,
              origin: ContentOrigin.admin,
              title: title,
              companyName: '',
              summary: summary,
              description: description,
              rowVersion: 1,
              priority: 0,
              audienceMode: 'all',
            ))
        .copyWith(
          title: title,
          companyName: _companyController.text.trim(),
          summary: summary,
          description: description,
          employmentType: _employmentType,
          workFormat: _workFormat,
          location: _locationController.text.trim().isEmpty
              ? null
              : _locationController.text.trim(),
          salaryText: _salaryController.text.trim().isEmpty
              ? null
              : _salaryController.text.trim(),
          externalUrl: _urlController.text.trim().isEmpty
              ? null
              : _urlController.text.trim(),
          contacts: _contactsFromFields(),
          expiresAt: _expiresAt,
          clearLocation: _locationController.text.trim().isEmpty,
          clearSalaryText: _salaryController.text.trim().isEmpty,
          clearExternalUrl: _urlController.text.trim().isEmpty,
          clearEmploymentType: _employmentType == null,
          clearWorkFormat: _workFormat == null,
          clearExpiresAt: _expiresAt == null,
        );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final draft = _draftFromFields();
    if (draft == null) {
      setState(
        () => _banner =
            'Нельзя создать: заполните название и краткое описание '
            '(fail-closed, запись не создана).',
      );
      return;
    }
    await _run(() async {
      final origin = ContentOrigin.tryParse(_origin);
      if (origin != ContentOrigin.admin && origin != ContentOrigin.demo) {
        setState(() => _banner = 'Ручное создание только с origin admin|demo.');
        return;
      }
      final created = await _repository.createDraft(
        draft: draft,
        origin: origin!,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = created.id;
        _banner = 'Черновик вакансии создан.';
      });
      final selected = _selected;
      if (selected != null) _bind(selected);
    });
  }

  Future<void> _save() async {
    final selected = _selected;
    if (selected == null) return;
    final draft = _draftFromFields(base: selected);
    if (draft == null) {
      setState(() => _banner = 'Проверьте поля (fail-closed parse).');
      return;
    }
    await _run(() async {
      var next = await _repository.updateDraft(draft);
      next = await _repository.setAudience(
        id: next.id,
        audienceMode: _audienceMode,
        groupIds: _groupIds,
        userIds: _userIds,
        expectedRowVersion: next.rowVersion,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = next.id;
        _banner = 'Сохранено.';
        _audiencePreview = null;
      });
      final rebound = _selected;
      if (rebound != null) _bind(rebound);
    });
  }

  Future<void> _previewAudience() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final preview = await _repository.previewAudience(selected.id);
      if (!mounted) return;
      setState(() => _audiencePreview = preview);
    });
  }

  Future<void> _publish() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final published = await _repository.publish(
        selected.id,
        selected.rowVersion,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = published.id;
        _banner = 'Опубликовано.';
      });
      final rebound = _selected;
      if (rebound != null) _bind(rebound);
    });
  }

  Future<void> _lifecycle(String action) async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final updated = await _repository.setLifecycle(
        id: selected.id,
        action: action,
        expectedRowVersion: selected.rowVersion,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = updated.id;
        _banner = switch (action) {
          'unpublish' => 'Снято с публикации.',
          'expire' => 'Помечено истекшей.',
          'archive' => 'Архивировано.',
          _ => 'Обновлено.',
        };
      });
    });
  }

  Future<void> _uploadAsset() async {
    final selected = _selected;
    if (selected == null) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;
    final ext = (file.extension ?? '').toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      _ => 'image/jpeg',
    };
    await _run(() async {
      final assetId = await _repository.registerAsset(
        vacancyId: selected.id,
        bytes: bytes,
        contentType: mime,
        title: file.name,
      );
      await _reload();
      if (!mounted) return;
      setState(() => _banner = 'Вложение добавлено: $assetId');
    });
  }

  Future<void> _pickExpiresAt() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _expiresAt ?? DateTime.now().add(const Duration(days: 30)),
      firstDate: DateTime.now(),
      lastDate: DateTime(2035),
    );
    if (date == null) return;
    setState(() => _expiresAt = date);
  }

  Future<void> _resolveReport(VacancyReportEntry report, String action) async {
    await _run(() async {
      await _repository.resolveReport(reportId: report.id, action: action);
      await _loadReports();
      if (!mounted) return;
      setState(() => _banner = 'Жалоба обработана.');
    });
  }

  Future<void> _moderate(String action) async {
    final selected = _selected;
    if (selected == null) return;
    String? reason;
    if (action == 'reject') {
      reason = await showDialog<String>(
        context: context,
        builder: (context) {
          final controller = TextEditingController();
          return AlertDialog(
            title: const Text('Причина отклонения'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Причина (обязательно)',
              ),
              maxLines: 3,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('Отклонить'),
              ),
            ],
          );
        },
      );
      if (reason == null || reason.isEmpty) return;
    }
    await _run(() async {
      final updated = await _repository.moderate(
        id: selected.id,
        action: action,
        expectedRowVersion: selected.rowVersion,
        reason: reason,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = updated.id;
        _banner = switch (action) {
          'take_in_moderation' => 'Взято на модерацию.',
          'approve' => 'Одобрено.',
          'reject' => 'Отклонено.',
          _ => 'Обновлено.',
        };
      });
      final rebound = _selected;
      if (rebound != null) _bind(rebound);
    });
  }

  bool get _draftOnly {
    final selected = _selected;
    if (selected == null) return true;
    return selected.status == VacancyStatus.draft ||
        selected.status == VacancyStatus.submitted ||
        selected.status == VacancyStatus.rejected;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(child: Text(_loadError!));
    }

    final selected = _selected;
    final preview =
        _draftFromFields(base: selected)?.previewPayload ??
        VacancyCardPayload.demoVacancies.first;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Вакансии',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Отдельная доменная модель Stage 17. '
                'User submission не публикуется автоматически.',
              ),
              const SizedBox(height: 12),
              if (_canWrite)
                FilledButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.add),
                  label: const Text('Новая вакансия'),
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    return ListTile(
                      selected: item.id == _selectedId,
                      title: Text(item.title),
                      subtitle: Text(
                        '${_statusRu(item.status)} · ${item.origin.labelRu}',
                      ),
                      onTap: () {
                        setState(() => _selectedId = item.id);
                        _bind(item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 24),
        Expanded(
          child: selected == null
              ? const Center(child: Text('Создайте вакансию.'))
              : ListView(
                  children: [
                    if (_banner != null) ...[
                      Text(_banner!),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      'Preview (тот же виджет, что Mobile)',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 560,
                      child: AdminStudentPhoneFrame(
                        showBottomNavigation: true,
                        navigationIndex: 1,
                        child: Scaffold(
                          backgroundColor: const Color(0xFFFAF8FC),
                          appBar: AppBar(
                            title: const Text('Вакансии'),
                            backgroundColor: const Color(0xFFFAF8FC),
                            surfaceTintColor: Colors.transparent,
                          ),
                          body: ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              const Text(
                                'Для студентов',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 12),
                              StudentVacancyCard(
                                payload: preview,
                                showDemoBadge:
                                    selected.origin == ContentOrigin.demo,
                                expiresLabel: vacancyExpiresLabel(_expiresAt),
                                hasContacts: _contactsFromFields().isNotEmpty,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Статус: ${_statusRu(selected.status)} · '
                      '${selected.origin.labelRu}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (selected.rejectionReason != null &&
                        selected.rejectionReason!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Причина отклонения: ${selected.rejectionReason}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(labelText: 'Название'),
                      enabled: _canWrite && _draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _companyController,
                      decoration: const InputDecoration(
                        labelText: 'Организация',
                      ),
                      enabled: _canWrite && _draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _summaryController,
                      decoration: const InputDecoration(
                        labelText: 'Краткое описание',
                      ),
                      enabled: _canWrite && _draftOnly,
                      maxLines: 2,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Полное описание',
                      ),
                      enabled: _canWrite && _draftOnly,
                      maxLines: 4,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _requirementsController,
                      decoration: const InputDecoration(
                        labelText: 'Требования',
                      ),
                      enabled: _canWrite && _draftOnly,
                      maxLines: 3,
                      onChanged: (_) => setState(() {}),
                    ),
                    DropdownButtonFormField<VacancyEmploymentType?>(
                      key: ValueKey('employment-$_employmentType'),
                      initialValue: _employmentType,
                      decoration: const InputDecoration(
                        labelText: 'Формат занятости',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('— не указано —'),
                        ),
                        ...VacancyEmploymentType.values.map(
                          (e) => DropdownMenuItem(
                            value: e,
                            child: Text(e.labelRu),
                          ),
                        ),
                      ],
                      onChanged: !_canWrite || !_draftOnly
                          ? null
                          : (value) => setState(() => _employmentType = value),
                    ),
                    DropdownButtonFormField<VacancyWorkFormat?>(
                      key: ValueKey('format-$_workFormat'),
                      initialValue: _workFormat,
                      decoration: const InputDecoration(
                        labelText: 'Местоположение / удалённо',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('— не указано —'),
                        ),
                        ...VacancyWorkFormat.values.map(
                          (e) => DropdownMenuItem(
                            value: e,
                            child: Text(e.labelRu),
                          ),
                        ),
                      ],
                      onChanged: !_canWrite || !_draftOnly
                          ? null
                          : (value) => setState(() => _workFormat = value),
                    ),
                    TextField(
                      controller: _locationController,
                      decoration: const InputDecoration(
                        labelText: 'Местоположение (текст)',
                      ),
                      enabled: _canWrite && _draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _salaryController,
                      decoration: const InputDecoration(
                        labelText: 'Зарплата (optional)',
                      ),
                      enabled: _canWrite && _draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(labelText: 'Ссылка'),
                      enabled: _canWrite && _draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Контакты',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextField(
                      controller: _contactEmailController,
                      decoration: const InputDecoration(labelText: 'Email'),
                      enabled: _canWrite && _draftOnly,
                      keyboardType: TextInputType.emailAddress,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _contactPhoneController,
                      decoration: const InputDecoration(labelText: 'Телефон'),
                      enabled: _canWrite && _draftOnly,
                      keyboardType: TextInputType.phone,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _contactTelegramController,
                      decoration: const InputDecoration(labelText: 'Telegram'),
                      enabled: _canWrite && _draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              labelText: 'Срок актуальности',
                            ),
                            child: Text(
                              _expiresAt == null
                                  ? '— не указан —'
                                  : vacancyExpiresLabel(_expiresAt!) ??
                                        _expiresAt!.toLocal().toString(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: !_canWrite || !_draftOnly || _busy
                              ? null
                              : _pickExpiresAt,
                          child: const Text('Выбрать'),
                        ),
                        if (_expiresAt != null)
                          IconButton(
                            tooltip: 'Очистить',
                            onPressed: !_canWrite || !_draftOnly || _busy
                                ? null
                                : () => setState(() => _expiresAt = null),
                            icon: const Icon(Icons.clear),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (selected.origin == ContentOrigin.userSubmission ||
                        selected.origin == ContentOrigin.importSource)
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Источник',
                        ),
                        child: Text(selected.origin.labelRu),
                      )
                    else
                      DropdownButtonFormField<String>(
                        key: ValueKey('origin-$_origin'),
                        initialValue: _origin,
                        decoration: const InputDecoration(
                          labelText: 'Источник',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'admin',
                            child: Text('Админ'),
                          ),
                          DropdownMenuItem(value: 'demo', child: Text('Demo')),
                        ],
                        onChanged: !_canWrite || !_draftOnly
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() => _origin = value);
                              },
                      ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('audience-$_audienceMode'),
                      initialValue: _audienceMode,
                      decoration: const InputDecoration(labelText: 'Аудитория'),
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('Все')),
                        DropdownMenuItem(
                          value: 'groups',
                          child: Text('Группы'),
                        ),
                        DropdownMenuItem(
                          value: 'users',
                          child: Text('Пользователи'),
                        ),
                        DropdownMenuItem(
                          value: 'groups_and_users',
                          child: Text('Группы и пользователи'),
                        ),
                      ],
                      onChanged: !_canWrite || !_draftOnly
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _audienceMode = value;
                                _audiencePreview = null;
                              });
                            },
                    ),
                    ContentAudienceSelectors(
                      studentsRepository: _studentsRepository,
                      audienceMode: _audienceMode,
                      selectedGroupIds: _groupIds,
                      selectedUserIds: _userIds,
                      enabled: _canWrite && _draftOnly,
                      onChanged: ({required groupIds, required userIds}) {
                        setState(() {
                          _groupIds = groupIds;
                          _userIds = userIds;
                          _audiencePreview = null;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _previewAudience,
                      icon: const Icon(Icons.preview_outlined),
                      label: const Text('Preview аудитории'),
                    ),
                    if (_audiencePreview != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Получателей: ${_audiencePreview!.recipientCount}. '
                        'Групп: ${_audiencePreview!.groupCount}. '
                        'Явных пользователей: '
                        '${_audiencePreview!.explicitUserCount}.',
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: !_canWrite || !_draftOnly || _busy
                              ? null
                              : _save,
                          child: const Text('Сохранить'),
                        ),
                        if (_canPublish &&
                            selected.status == VacancyStatus.approved)
                          FilledButton.tonal(
                            onPressed: _busy ? null : _publish,
                            child: const Text('Опубликовать'),
                          ),
                        if (_canModerate &&
                            selected.status == VacancyStatus.submitted)
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _moderate('take_in_moderation'),
                            child: const Text('На модерацию'),
                          ),
                        if (_canModerate &&
                            selected.status == VacancyStatus.inModeration)
                          FilledButton.tonal(
                            onPressed: _busy
                                ? null
                                : () => _moderate('approve'),
                            child: const Text('Одобрить'),
                          ),
                        if (_canModerate &&
                            (selected.status == VacancyStatus.submitted ||
                                selected.status == VacancyStatus.inModeration))
                          OutlinedButton(
                            onPressed: _busy ? null : () => _moderate('reject'),
                            child: const Text('Отклонить'),
                          ),
                        if (_canPublish &&
                            selected.status == VacancyStatus.published)
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _lifecycle('unpublish'),
                            child: const Text('Снять с публикации'),
                          ),
                        if (_canPublish &&
                            selected.status == VacancyStatus.published)
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _lifecycle('expire'),
                            child: const Text('Истекла'),
                          ),
                        if (_canPublish &&
                            selected.status != VacancyStatus.archived)
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _lifecycle('archive'),
                            child: const Text('В архив'),
                          ),
                        if (_canWrite && _draftOnly)
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _uploadAsset,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: const Text('Загрузить вложение'),
                          ),
                      ],
                    ),
                    if (selected.assetIds.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Вложения: ${selected.assetIds.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_moderationJournal.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Журнал модерации',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final entry in _moderationJournal.take(8))
                        Text(
                          '${entry.action}'
                          '${entry.fromStatus != null ? ' (${entry.fromStatus}→${entry.toStatus})' : ''}'
                          '${entry.reasonText.isNotEmpty ? ': ${entry.reasonText}' : ''}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                    if (_versions.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Версии: ${_versions.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_openReports.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Открытые жалобы (${_openReports.length})',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      for (final report in _openReports.take(5))
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            report.vacancyTitle ?? report.vacancyId,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          subtitle: Text(
                            '${report.reasonCode} · ${report.status}',
                          ),
                          trailing: _canModerate
                              ? Wrap(
                                  spacing: 4,
                                  children: [
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _resolveReport(
                                              report,
                                              'resolve',
                                            ),
                                      child: const Text('Resolve'),
                                    ),
                                    TextButton(
                                      onPressed: _busy
                                          ? null
                                          : () => _resolveReport(
                                              report,
                                              'reject',
                                            ),
                                      child: const Text('Reject'),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                    ],
                    if (selected.status != VacancyStatus.approved &&
                        selected.status != VacancyStatus.published) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Публикация доступна только после одобрения модерацией '
                        '(approved).',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}
