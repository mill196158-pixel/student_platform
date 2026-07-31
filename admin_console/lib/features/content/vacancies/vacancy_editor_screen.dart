import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../academic/students/students_repository.dart';
import '../profile_feed/content_audience_selectors.dart';
import '../shared/admin_content_backend.dart';
import '../shared/content_media_intent.dart';
import '../shared/content_preview_binder.dart';
import '../shared/content_preview_mode.dart';
import '../shared/content_technical_panel.dart';
import '../shared/phone_preview_frame.dart';
import '../shared/visual_editor_list_panel.dart';
import '../shared/visual_editor_shell.dart';
import '../shared/visual_editor_states.dart';
import 'supabase_vacancy_repository.dart';
import 'vacancy_item.dart';
import 'vacancy_preview.dart';
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
  VisualEditorListTab _listTab = VisualEditorListTab.drafts;
  bool _showDemoOnly = false;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  bool _editingWorkingDraft = false;
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
  String? _successBanner;
  String? _loadError;
  late final StudentsRepository _studentsRepository = _defaultStudentsRepo();
  _EditorSnapshot? _boundSnapshot;
  ContentPreviewMode _previewMode = ContentPreviewMode.effectiveDraft;
  ContentMediaIntentState _logoMedia = ContentMediaIntentState.untouched;
  ContentMediaIntentState _coverMedia = ContentMediaIntentState.untouched;
  ContentMediaIntentState _backgroundMedia = ContentMediaIntentState.untouched;

  VacancyAdminListPartitions get _partitions => partitionAdminVacancy(_items);

  VisualEditorTabCounts get _tabCounts => VisualEditorTabCounts(
    published: _partitions.published.length,
    drafts: _partitions.drafts.length,
    archived: _partitions.archived.length,
  );

  List<VacancyItem> get _tabItems {
    final parts = _partitions;
    final base = switch (_listTab) {
      VisualEditorListTab.published => parts.published,
      VisualEditorListTab.drafts => parts.drafts,
      VisualEditorListTab.archived => parts.archived,
    };
    if (!_showDemoOnly) return base;
    return base.where((item) => item.origin == ContentOrigin.demo).toList();
  }

  bool get _isDemoBackend =>
      AdminBackendConfig.isDemoMode || _repository is LocalVacancyRepository;

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
    return AdminContentBackend.resolveRepository<VacancyRepository>(
      isDemoMode: AdminBackendConfig.isDemoMode,
      client: _tryClient(),
      localFactory: LocalVacancyRepository.new,
      supabaseFactory: (client) => SupabaseVacancyRepository(client: client),
    );
  }

  StudentsRepository _defaultStudentsRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalStudentsRepository();
    final client = _tryClient();
    if (client != null) return SupabaseStudentsRepository(client: client);
    if (widget.repository != null) return LocalStudentsRepository();
    throw StateError(AdminContentBackend.realUnavailableMessage);
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
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

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final items = await _repository.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _ensureSelectionForTab();
      });
      _bindSelected();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _reload({String? selectId}) async {
    setState(() {
      _loading = false;
      _loadError = null;
    });
    try {
      final items = await _repository.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        if (selectId != null) _selectedId = selectId;
        _ensureSelectionForTab();
      });
      _bindSelected();
      final selected = _selected;
      if (selected != null) unawaited(_loadJournal(selected));
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.toString());
    }
  }

  void _ensureSelectionForTab() {
    final tabItems = _tabItems;
    if (tabItems.isEmpty) {
      _selectedId = null;
      return;
    }
    if (_selectedId != null && tabItems.any((e) => e.id == _selectedId)) {
      return;
    }
    _selectedId = tabItems.first.id;
  }

  void _select(String id) {
    if (id == _selectedId) return;
    setState(() {
      _selectedId = id;
      _editingWorkingDraft = false;
    });
    _bindSelected();
    final selected = _selected;
    if (selected != null) unawaited(_loadJournal(selected));
  }

  Future<void> _beginEdit() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _run(() async {
      final item = await _repository.beginEdit(selected.id);
      await _reload(selectId: item.id);
      if (!mounted) return;
      setState(() => _editingWorkingDraft = true);
      _bindSelected();
    });
  }

  Future<void> _discardWorkingDraft() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _run(() async {
      final item = await _repository.discardWorkingDraft(selected.id);
      await _reload(selectId: item.id);
      if (!mounted) return;
      setState(() {
        _editingWorkingDraft = false;
        _successBanner = 'Изменения отменены.';
      });
      _bindSelected();
    });
  }

  _EditorSnapshot _captureSnapshot() {
    return _EditorSnapshot(
      title: _titleController.text,
      company: _companyController.text,
      summary: _summaryController.text,
      description: _descriptionController.text,
      requirements: _requirementsController.text,
      location: _locationController.text,
      salary: _salaryController.text,
      url: _urlController.text,
      contactEmail: _contactEmailController.text,
      contactPhone: _contactPhoneController.text,
      contactTelegram: _contactTelegramController.text,
      employmentType: _employmentType,
      workFormat: _workFormat,
      audienceMode: _audienceMode,
      origin: _origin,
      groupIds: [..._groupIds],
      userIds: [..._userIds],
      expiresAt: _expiresAt,
    );
  }

  void _markDirty() {
    final nextDirty =
        _boundSnapshot != null && _captureSnapshot() != _boundSnapshot;
    setState(() => _dirty = nextDirty);
  }

  void _bindSelected() {
    final item = _selected;
    if (item == null) {
      _boundSnapshot = null;
      setState(() {
        _dirty = false;
        _banner = null;
        _successBanner = null;
      });
      return;
    }
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
    _logoMedia = _mediaIntentForRole(item, 'logo');
    _coverMedia = _mediaIntentForRole(item, 'cover');
    _backgroundMedia = _mediaIntentForRole(item, 'background');
    _boundSnapshot = _captureSnapshot();
    setState(() {
      _dirty = false;
      _banner = null;
      _successBanner = null;
    });
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
      _successBanner = null;
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
      await _reload(selectId: created.id);
      if (!mounted) return;
      setState(() {
        _listTab = VisualEditorListTab.drafts;
        _successBanner = 'Черновик вакансии создан.';
      });
    });
  }

  Future<void> _createDemoDraft() async {
    final seed = VacancyCardPayload.demoVacancies.first;
    final draft = VacancyItem(
      id: '',
      status: VacancyStatus.draft,
      origin: ContentOrigin.demo,
      title: seed.title,
      companyName: seed.companyName,
      summary: seed.summary,
      description: seed.summary,
      employmentType: seed.employmentType,
      workFormat: seed.workFormat,
      location: seed.location,
      salaryText: seed.salaryText,
      externalUrl: seed.externalUrl,
      rowVersion: 1,
      priority: 0,
      audienceMode: 'all',
    );
    await _run(() async {
      final created = await _repository.createDraft(
        draft: draft,
        origin: ContentOrigin.demo,
      );
      await _reload(selectId: created.id);
      if (mounted) {
        setState(() {
          _listTab = VisualEditorListTab.drafts;
          _successBanner = 'Демо-черновик создан локально.';
        });
      }
    });
  }

  Future<void> _promoteDemo() async {
    final selected = _selected;
    if (selected == null || selected.origin != ContentOrigin.demo) return;
    await _run(() async {
      final updated = await _repository.promoteDemo(
        selected.id,
        selected.rowVersion,
      );
      await _reload(selectId: updated.id);
      if (mounted) {
        setState(
          () => _successBanner = 'Демо-вакансия переведена в управляемую.',
        );
      }
    });
  }

  Future<void> _safeDelete() async {
    final selected = _selected;
    if (selected == null || selected.status != VacancyStatus.archived) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить навсегда?'),
        content: const Text(
          'Вакансия будет удалена безвозвратно. '
          'Демо-ключ будет помечен и не вернётся при bootstrap.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _repository.safeDelete(selected.id, selected.rowVersion);
      await _reload();
      if (mounted) {
        setState(() => _successBanner = 'Вакансия удалена.');
      }
    });
  }

  Future<void> _saveDraft() async {
    if (!_canWrite) {
      setState(() => _banner = 'Недостаточно прав для сохранения.');
      return;
    }
    await _save();
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
      if (_editingWorkingDraft) {
        final draftVersion = selected.workingDraftRowVersion;
        if (draftVersion == null) {
          setState(() => _banner = 'Черновик изменений не найден.');
          return;
        }
        final next = await _repository.saveWorkingDraft(
          draft,
          expectedDraftRowVersion: draftVersion,
        );
        await _reload(selectId: next.id);
        if (!mounted) return;
        setState(() {
          _successBanner = 'Изменения сохранены.';
          _audiencePreview = null;
          _dirty = false;
          _boundSnapshot = _captureSnapshot();
        });
        return;
      }
      var next = await _repository.updateDraft(draft);
      next = await _repository.setAudience(
        id: next.id,
        audienceMode: _audienceMode,
        groupIds: _groupIds,
        userIds: _userIds,
        expectedRowVersion: next.rowVersion,
      );
      await _reload(selectId: next.id);
      if (!mounted) return;
      setState(() {
        _successBanner = 'Сохранено.';
        _audiencePreview = null;
        _dirty = false;
        _boundSnapshot = _captureSnapshot();
      });
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
      if (_dirty) {
        await _save();
        if (_dirty) return;
      }
      if (_editingWorkingDraft) {
        final current = _selected;
        if (current == null) return;
        final draftVersion = current.workingDraftRowVersion;
        if (draftVersion == null) {
          setState(() => _banner = 'Черновик изменений не найден.');
          return;
        }
        final published = await _repository.publishWorkingDraft(
          current.id,
          expectedDraftRowVersion: draftVersion,
        );
        await _reload(selectId: published.id);
        if (!mounted) return;
        setState(() {
          _editingWorkingDraft = false;
          _listTab = VisualEditorListTab.published;
          _successBanner = 'Изменения опубликованы.';
        });
        return;
      }
      final published = await _repository.publish(
        selected.id,
        selected.rowVersion,
      );
      await _reload(selectId: published.id);
      if (!mounted) return;
      setState(() {
        _listTab = VisualEditorListTab.published;
        _successBanner = 'Опубликовано.';
      });
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
      await _reload(selectId: updated.id);
      if (!mounted) return;
      setState(() {
        _successBanner = switch (action) {
          'unpublish' => 'Снято с публикации.',
          'expire' => 'Помечено истекшей.',
          'archive' => 'Архивировано.',
          _ => 'Обновлено.',
        };
        _listTab = switch (action) {
          'unpublish' => VisualEditorListTab.drafts,
          'expire' || 'archive' => VisualEditorListTab.archived,
          _ => _listTab,
        };
      });
    });
  }

  Future<void> _uploadAsset({String role = 'attachment'}) async {
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
    if (bytes.length > 5 * 1024 * 1024) {
      setState(() => _banner = 'Файл больше 5 МБ.');
      return;
    }
    final ext = (file.extension ?? '').toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      _ => 'image/jpeg',
    };
    final isImage = mime.startsWith('image/');
    if (isImage && role == 'logo') {
      setState(() {
        _logoMedia = _logoMedia.pickLocal(Uint8List.fromList(bytes));
        _dirty = true;
      });
    } else if (isImage && role == 'cover') {
      setState(() {
        _coverMedia = _coverMedia.pickLocal(Uint8List.fromList(bytes));
        _dirty = true;
      });
    } else if (isImage && role == 'background') {
      setState(() {
        _backgroundMedia = _backgroundMedia.pickLocal(
          Uint8List.fromList(bytes),
        );
        _dirty = true;
      });
    }
    await _run(() async {
      if (isImage && role == 'logo') {
        setState(() => _logoMedia = _logoMedia.markUploading());
      } else if (isImage && role == 'cover') {
        setState(() => _coverMedia = _coverMedia.markUploading());
      } else if (isImage && role == 'background') {
        setState(() => _backgroundMedia = _backgroundMedia.markUploading());
      }
      try {
        final previousId = switch (role) {
          'logo' => _logoMedia.assetId,
          'cover' => _coverMedia.assetId,
          'background' => _backgroundMedia.assetId,
          _ => null,
        };
        final previousIsDraft = previousId == null
            ? false
            : selected.assets.any((a) => a.id == previousId && a.isDraftAsset);
        final assetId = await _repository.registerAsset(
          vacancyId: selected.id,
          bytes: bytes,
          contentType: mime,
          title: file.name,
          role: role,
        );
        // Only delete a prior draft-cohort asset. Canonical replacement
        // is deferred until working-draft publish.
        if (previousIsDraft &&
            previousId != null &&
            previousId.isNotEmpty &&
            previousId != assetId &&
            (role == 'logo' || role == 'cover' || role == 'background')) {
          try {
            await _repository.deleteAsset(previousId);
          } catch (_) {
            // Draft demotion already keeps one primary; delete is best-effort.
          }
        }
        await _reload();
        if (!mounted) return;
        setState(() {
          if (isImage && role == 'logo') {
            _logoMedia = _logoMedia.markUploaded(assetId);
          } else if (isImage && role == 'cover') {
            _coverMedia = _coverMedia.markUploaded(assetId);
          } else if (isImage && role == 'background') {
            _backgroundMedia = _backgroundMedia.markUploaded(assetId);
          }
          _banner = null;
          _successBanner = switch (role) {
            'logo' => 'Логотип обновлён',
            'cover' => 'Обложка обновлена',
            'background' => 'Фон обновлён',
            _ => 'Вложение добавлено',
          };
        });
      } catch (error) {
        if (!mounted) return;
        setState(() {
          if (isImage && role == 'logo') {
            _logoMedia = _logoMedia.markFailed(error.toString());
          } else if (isImage && role == 'cover') {
            _coverMedia = _coverMedia.markFailed(error.toString());
          } else if (isImage && role == 'background') {
            _backgroundMedia = _backgroundMedia.markFailed(error.toString());
          }
          _banner = 'Не удалось загрузить файл.';
        });
      }
    });
  }

  ContentMediaIntentState _mediaIntentForRole(VacancyItem item, String role) {
    if (item.isVisualRoleCleared(role) && item.assetIdForRole(role) == null) {
      return const ContentMediaIntentState(phase: ContentMediaPhase.removed);
    }
    final assetId = item.assetIdForRole(role);
    if (assetId == null) return ContentMediaIntentState.untouched;
    return ContentMediaIntentState(
      phase: ContentMediaPhase.uploaded,
      assetId: assetId,
    );
  }

  Future<void> _clearVisualAsset(String role) async {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      if (role == 'logo') {
        _logoMedia = _logoMedia.markRemoved();
      } else if (role == 'cover') {
        _coverMedia = _coverMedia.markRemoved();
      } else {
        _backgroundMedia = _backgroundMedia.markRemoved();
      }
      _dirty = true;
    });
    await _run(() async {
      try {
        final updated = await _repository.clearVisualRole(
          vacancyId: selected.id,
          role: role,
        );
        await _reload();
        if (!mounted) return;
        setState(() {
          _selectedId = updated.id;
          if (role == 'logo') {
            _logoMedia = _mediaIntentForRole(updated, 'logo');
          } else if (role == 'cover') {
            _coverMedia = _mediaIntentForRole(updated, 'cover');
          } else {
            _backgroundMedia = _mediaIntentForRole(updated, 'background');
          }
          _successBanner = switch (role) {
            'logo' => 'Логотип убран из черновика',
            'cover' => 'Обложка убрана из черновика',
            _ => 'Фон убран из черновика',
          };
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _banner = 'Не удалось удалить изображение.');
      }
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
    _markDirty();
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
      await _reload(selectId: updated.id);
      if (!mounted) return;
      setState(() {
        _successBanner = switch (action) {
          'take_in_moderation' => 'Взято на модерацию.',
          'approve' => 'Одобрено.',
          'reject' => 'Отклонено.',
          _ => 'Обновлено.',
        };
      });
    });
  }

  Future<void> _unpublish() async => _lifecycle('unpublish');

  Future<void> _showVersions() async {
    final selected = _selected;
    if (selected == null) return;
    List<VacancyVersionEntry>? versions;
    await _run(() async {
      versions = await _repository.listVersions(selected.id);
    });
    if (versions == null || !mounted) return;
    if (versions!.isEmpty) {
      setState(() => _successBanner = 'История версий пуста.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('История версий'),
        content: SizedBox(
          width: 380,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: versions!.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final version = versions![index];
              return ListTile(
                leading: CircleAvatar(child: Text('${version.versionNumber}')),
                title: Text('Версия ${version.versionNumber}'),
                subtitle: version.snapshotTitle == null
                    ? null
                    : Text(version.snapshotTitle!),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _handlePopDirtyConfirm() async {
    final navigator = Navigator.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Несохранённые изменения'),
        content: const Text('Выйти без сохранения черновика?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      navigator.maybePop();
    }
  }

  void _openVacancyDetail(ManagedVacancyCard card) {
    _select(card.id);
  }

  List<ManagedVacancyCard> _previewCards() {
    final selected = _selected;
    final published = _partitions.publishedPreviewItems;
    final cards = published.map((item) => item.toManagedCard()).toList();
    if (selected == null) return cards;

    if (_previewMode == ContentPreviewMode.publishedCanonical) {
      return cards;
    }

    if (!shouldOverlayLiveDraft(
      isDraft: selected.status != VacancyStatus.published,
      editingWorkingDraft: _editingWorkingDraft,
      dirty: _dirty,
      mode: _previewMode,
    )) {
      return cards;
    }

    final draft = _draftFromFields(base: selected);
    if (draft == null) return cards;

    final overlay = ManagedVacancyCard(
      id: draft.id.isEmpty ? 'preview' : draft.id,
      origin: draft.origin,
      payload: draft.previewPayload,
      showDemoBadge: selected.origin == ContentOrigin.demo,
      hasContacts: draft.contacts.isNotEmpty,
      expiresAt: draft.expiresAt,
      logoBytes: _logoMedia.bytesForPreview,
      coverBytes: _coverMedia.bytesForPreview,
      backgroundBytes: _backgroundMedia.bytesForPreview,
    );
    final index = cards.indexWhere((c) => c.id == selected.id);
    if (index >= 0) {
      return [...cards]..[index] = overlay;
    }
    return [overlay, ...cards];
  }

  void _discardLocalChanges() {
    final snapshot = _boundSnapshot;
    if (snapshot == null) return;
    _titleController.text = snapshot.title;
    _companyController.text = snapshot.company;
    _summaryController.text = snapshot.summary;
    _descriptionController.text = snapshot.description;
    _locationController.text = snapshot.location;
    _salaryController.text = snapshot.salary;
    _urlController.text = snapshot.url;
    _requirementsController.text = snapshot.requirements;
    _contactEmailController.text = snapshot.contactEmail;
    _contactPhoneController.text = snapshot.contactPhone;
    _contactTelegramController.text = snapshot.contactTelegram;
    _audienceMode = snapshot.audienceMode;
    _groupIds = [...snapshot.groupIds];
    _userIds = [...snapshot.userIds];
    _employmentType = snapshot.employmentType;
    _workFormat = snapshot.workFormat;
    _expiresAt = snapshot.expiresAt;
    _logoMedia = ContentMediaIntentState.untouched;
    _coverMedia = ContentMediaIntentState.untouched;
    _backgroundMedia = ContentMediaIntentState.untouched;
    setState(() => _dirty = false);
  }

  String? get _headerBanner => _banner;

  String? get _infoBanner {
    if (_banner != null) return null;
    return _successBanner;
  }

  bool get _draftOnly {
    final selected = _selected;
    if (selected == null) return true;
    if (_editingWorkingDraft) return true;
    return selected.status == VacancyStatus.draft ||
        selected.status == VacancyStatus.submitted ||
        selected.status == VacancyStatus.rejected;
  }

  bool get _canPublishSelected {
    final selected = _selected;
    if (selected == null || !_canPublish) return false;
    if (_editingWorkingDraft) return true;
    return selected.status == VacancyStatus.approved ||
        selected.status == VacancyStatus.draft;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: VisualEditorLoadingState(),
      );
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: VisualEditorErrorState(
          message: _loadError!,
          onRetry: () {
            setState(() => _loading = true);
            _bootstrap();
          },
        ),
      );
    }

    final selected = _selected;
    final previewCards = _previewCards();
    final isArchived =
        selected != null &&
        (selected.status == VacancyStatus.archived ||
            selected.status == VacancyStatus.expired);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: VisualEditorShell(
        title: 'Вакансии',
        selectedTitle: selected?.title,
        statusChip: selected?.status.russianLabel,
        originDemoBadge: selected?.origin == ContentOrigin.demo,
        dirty: _dirty,
        busy: _busy,
        banner: _headerBanner,
        defaultInfoMessage:
            _infoBanner ??
            'Заявки от студентов проходят модерацию перед публикацией. '
                'Черновики видны только в админке.',
        canWrite: _canWrite,
        canPublish: _canPublishSelected && selected != null && !isArchived,
        canUnpublish: _canPublish,
        isPublished: selected?.status == VacancyStatus.published,
        isArchived: isArchived,
        listTab: _listTab,
        tabCounts: _tabCounts,
        onTabChanged: (tab) {
          setState(() {
            _listTab = tab;
            _editingWorkingDraft = false;
            _ensureSelectionForTab();
          });
          _bindSelected();
        },
        onCreate: _canWrite ? _create : null,
        onSaveDraft: _canWrite && _draftOnly ? _saveDraft : null,
        onPublish: _canPublishSelected ? _publish : null,
        onUnpublish: _canPublish ? _unpublish : null,
        onVersions: _showVersions,
        onPopDirtyConfirm: _handlePopDirtyConfirm,
        editingWorkingDraft: _editingWorkingDraft,
        onDiscardWorkingDraft: _editingWorkingDraft && _canWrite
            ? _discardWorkingDraft
            : null,
        onDiscardLocalChanges: _dirty && _canWrite
            ? _discardLocalChanges
            : null,
        listBuilder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: VisualEditorListPanel(
                panelTitle: 'Вакансии',
                tab: _listTab,
                tabCounts: _tabCounts,
                items: [
                  for (final item in _tabItems)
                    VisualEditorListItem(
                      id: item.id,
                      title: item.title,
                      subtitle: item.companyName,
                      isDemo: item.origin == ContentOrigin.demo,
                      statusLabel: item.status.russianLabel,
                    ),
                ],
                selectedId: _selectedId,
                onTabChanged: (tab) {
                  setState(() {
                    _listTab = tab;
                    _editingWorkingDraft = false;
                    _ensureSelectionForTab();
                  });
                  _bindSelected();
                },
                onSelected: _select,
                onCreate: _canWrite ? _create : null,
                showDemoOnly: _showDemoOnly,
                onDemoFilterChanged: (value) =>
                    setState(() => _showDemoOnly = value),
              ),
            ),
            if (_isDemoBackend && _canWrite) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _createDemoDraft,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Создать демо-черновик'),
              ),
            ],
          ],
        ),
        previewBuilder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ContentPreviewModeToggle(
              mode: _previewMode,
              onChanged: (mode) => setState(() => _previewMode = mode),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _VacancyPhonePreview(
                cards: previewCards,
                selectedId: selected?.id,
                onCardTap: _openVacancyDetail,
              ),
            ),
          ],
        ),
        propertiesBuilder: (_) => selected == null
            ? VisualEditorEmptyState(
                message: _tabItems.isEmpty
                    ? _listTab.emptyMessageRu
                    : 'Выберите вакансию',
                actionLabel: _canWrite && _tabItems.isEmpty ? 'Создать' : null,
                onAction: _canWrite && _tabItems.isEmpty ? _create : null,
              )
            : _VacancyPropertiesPanel(
                selected: selected,
                canWrite: _canWrite,
                canPublish: _canPublish,
                canModerate: _canModerate,
                busy: _busy,
                draftOnly: _draftOnly,
                editingWorkingDraft: _editingWorkingDraft,
                titleController: _titleController,
                companyController: _companyController,
                summaryController: _summaryController,
                descriptionController: _descriptionController,
                requirementsController: _requirementsController,
                locationController: _locationController,
                salaryController: _salaryController,
                urlController: _urlController,
                contactEmailController: _contactEmailController,
                contactPhoneController: _contactPhoneController,
                contactTelegramController: _contactTelegramController,
                employmentType: _employmentType,
                workFormat: _workFormat,
                expiresAt: _expiresAt,
                origin: _origin,
                audienceMode: _audienceMode,
                groupIds: _groupIds,
                userIds: _userIds,
                audiencePreview: _audiencePreview,
                moderationJournal: _moderationJournal,
                versions: _versions,
                openReports: _openReports,
                studentsRepository: _studentsRepository,
                onChanged: _markDirty,
                onEmploymentTypeChanged: (value) {
                  setState(() => _employmentType = value);
                  _markDirty();
                },
                onWorkFormatChanged: (value) {
                  setState(() => _workFormat = value);
                  _markDirty();
                },
                onExpiresAtChanged: (value) {
                  setState(() => _expiresAt = value);
                  _markDirty();
                },
                onOriginChanged: (value) {
                  setState(() => _origin = value);
                  _markDirty();
                },
                onAudienceModeChanged: (value) {
                  setState(() {
                    _audienceMode = value;
                    _audiencePreview = null;
                  });
                  _markDirty();
                },
                onAudienceChanged: ({required groupIds, required userIds}) {
                  setState(() {
                    _groupIds = groupIds;
                    _userIds = userIds;
                    _audiencePreview = null;
                  });
                  _markDirty();
                },
                onPickExpiresAt: _pickExpiresAt,
                onPreviewAudience: _previewAudience,
                onSave: _saveDraft,
                onPublish: _publish,
                onModerate: _moderate,
                onLifecycle: _lifecycle,
                onPromoteDemo: _promoteDemo,
                onBeginEdit: selected.isPublished && !isArchived
                    ? _beginEdit
                    : null,
                onSafeDelete: _safeDelete,
                onUploadAsset: () => _uploadAsset(),
                onUploadLogo: () => _uploadAsset(role: 'logo'),
                onUploadCover: () => _uploadAsset(role: 'cover'),
                onUploadBackground: () => _uploadAsset(role: 'background'),
                onClearLogo: () => _clearVisualAsset('logo'),
                onClearCover: () => _clearVisualAsset('cover'),
                onClearBackground: () => _clearVisualAsset('background'),
                onResolveReport: _resolveReport,
              ),
      ),
    );
  }
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.title,
    required this.company,
    required this.summary,
    required this.description,
    required this.requirements,
    required this.location,
    required this.salary,
    required this.url,
    required this.contactEmail,
    required this.contactPhone,
    required this.contactTelegram,
    required this.employmentType,
    required this.workFormat,
    required this.audienceMode,
    required this.origin,
    required this.groupIds,
    required this.userIds,
    required this.expiresAt,
  });

  final String title;
  final String company;
  final String summary;
  final String description;
  final String requirements;
  final String location;
  final String salary;
  final String url;
  final String contactEmail;
  final String contactPhone;
  final String contactTelegram;
  final VacancyEmploymentType? employmentType;
  final VacancyWorkFormat? workFormat;
  final String audienceMode;
  final String origin;
  final List<String> groupIds;
  final List<String> userIds;
  final DateTime? expiresAt;

  @override
  bool operator ==(Object other) {
    return other is _EditorSnapshot &&
        other.title == title &&
        other.company == company &&
        other.summary == summary &&
        other.description == description &&
        other.requirements == requirements &&
        other.location == location &&
        other.salary == salary &&
        other.url == url &&
        other.contactEmail == contactEmail &&
        other.contactPhone == contactPhone &&
        other.contactTelegram == contactTelegram &&
        other.employmentType == employmentType &&
        other.workFormat == workFormat &&
        other.audienceMode == audienceMode &&
        other.origin == origin &&
        _listEq(other.groupIds, groupIds) &&
        _listEq(other.userIds, userIds) &&
        other.expiresAt == expiresAt;
  }

  @override
  int get hashCode => Object.hash(
    title,
    company,
    summary,
    description,
    requirements,
    location,
    salary,
    url,
    contactEmail,
    contactPhone,
    contactTelegram,
    employmentType,
    workFormat,
    audienceMode,
    origin,
    Object.hashAll(groupIds),
    Object.hashAll(userIds),
    expiresAt,
  );
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _VacancyPhonePreview extends StatefulWidget {
  const _VacancyPhonePreview({
    required this.cards,
    required this.selectedId,
    required this.onCardTap,
  });

  final List<ManagedVacancyCard> cards;
  final String? selectedId;
  final ValueChanged<ManagedVacancyCard> onCardTap;

  @override
  State<_VacancyPhonePreview> createState() => _VacancyPhonePreviewState();
}

class _VacancyPhonePreviewState extends State<_VacancyPhonePreview> {
  ManagedVacancyCard? _detailCard;

  void _openDetail(ManagedVacancyCard card) {
    widget.onCardTap(card);
    setState(() => _detailCard = card);
  }

  @override
  Widget build(BuildContext context) {
    return PhonePreviewFrame(
      child: Theme(
        data: studentPlatformLightTheme(),
        child: SafeArea(
          child: StudentJobsBoardView(
            cards: widget.cards,
            selectedId: widget.selectedId,
            onOpenDetail: (id) {
              for (final card in widget.cards) {
                if (card.id == id) {
                  _openDetail(card);
                  break;
                }
              }
            },
            detailPayload: _detailCard,
            onBack: () => setState(() => _detailCard = null),
            emptyMessage: 'Нет опубликованных вакансий для предпросмотра',
          ),
        ),
      ),
    );
  }
}

class _VacancyPropertiesPanel extends StatelessWidget {
  const _VacancyPropertiesPanel({
    required this.selected,
    required this.canWrite,
    required this.canPublish,
    required this.canModerate,
    required this.busy,
    required this.draftOnly,
    required this.editingWorkingDraft,
    required this.titleController,
    required this.companyController,
    required this.summaryController,
    required this.descriptionController,
    required this.requirementsController,
    required this.locationController,
    required this.salaryController,
    required this.urlController,
    required this.contactEmailController,
    required this.contactPhoneController,
    required this.contactTelegramController,
    required this.employmentType,
    required this.workFormat,
    required this.expiresAt,
    required this.origin,
    required this.audienceMode,
    required this.groupIds,
    required this.userIds,
    required this.audiencePreview,
    required this.moderationJournal,
    required this.versions,
    required this.openReports,
    required this.studentsRepository,
    required this.onChanged,
    required this.onEmploymentTypeChanged,
    required this.onWorkFormatChanged,
    required this.onExpiresAtChanged,
    required this.onOriginChanged,
    required this.onAudienceModeChanged,
    required this.onAudienceChanged,
    required this.onPickExpiresAt,
    required this.onPreviewAudience,
    required this.onSave,
    required this.onPublish,
    required this.onModerate,
    required this.onLifecycle,
    required this.onPromoteDemo,
    this.onBeginEdit,
    required this.onSafeDelete,
    required this.onUploadAsset,
    required this.onUploadLogo,
    required this.onUploadCover,
    required this.onUploadBackground,
    required this.onClearLogo,
    required this.onClearCover,
    required this.onClearBackground,
    required this.onResolveReport,
  });

  final VacancyItem selected;
  final bool canWrite;
  final bool canPublish;
  final bool canModerate;
  final bool busy;
  final bool draftOnly;
  final bool editingWorkingDraft;
  final TextEditingController titleController;
  final TextEditingController companyController;
  final TextEditingController summaryController;
  final TextEditingController descriptionController;
  final TextEditingController requirementsController;
  final TextEditingController locationController;
  final TextEditingController salaryController;
  final TextEditingController urlController;
  final TextEditingController contactEmailController;
  final TextEditingController contactPhoneController;
  final TextEditingController contactTelegramController;
  final VacancyEmploymentType? employmentType;
  final VacancyWorkFormat? workFormat;
  final DateTime? expiresAt;
  final String origin;
  final String audienceMode;
  final List<String> groupIds;
  final List<String> userIds;
  final VacancyAudiencePreview? audiencePreview;
  final List<VacancyModerationEntry> moderationJournal;
  final List<VacancyVersionEntry> versions;
  final List<VacancyReportEntry> openReports;
  final StudentsRepository studentsRepository;
  final VoidCallback onChanged;
  final ValueChanged<VacancyEmploymentType?> onEmploymentTypeChanged;
  final ValueChanged<VacancyWorkFormat?> onWorkFormatChanged;
  final ValueChanged<DateTime?> onExpiresAtChanged;
  final ValueChanged<String> onOriginChanged;
  final ValueChanged<String> onAudienceModeChanged;
  final void Function({
    required List<String> groupIds,
    required List<String> userIds,
  })
  onAudienceChanged;
  final Future<void> Function() onPickExpiresAt;
  final Future<void> Function() onPreviewAudience;
  final Future<void> Function() onSave;
  final Future<void> Function() onPublish;
  final Future<void> Function(String action) onModerate;
  final Future<void> Function(String action) onLifecycle;
  final Future<void> Function() onPromoteDemo;
  final VoidCallback? onBeginEdit;
  final Future<void> Function() onSafeDelete;
  final Future<void> Function() onUploadAsset;
  final Future<void> Function() onUploadLogo;
  final Future<void> Function() onUploadCover;
  final Future<void> Function() onUploadBackground;
  final VoidCallback onClearLogo;
  final VoidCallback onClearCover;
  final VoidCallback onClearBackground;
  final Future<void> Function(VacancyReportEntry report, String action)
  onResolveReport;

  bool get _editable => canWrite && (draftOnly || editingWorkingDraft);

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ExpansionTile(
            title: const Text('Диагностика'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Отдельная доменная модель Stage 17. '
                  'User submission не публикуется автоматически.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          Text(
            'Свойства вакансии',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Text(
            'Статус: ${selected.status.russianLabel} · ${selected.origin.labelRu}',
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
            controller: titleController,
            decoration: const InputDecoration(labelText: 'Название'),
            enabled: _editable,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: companyController,
            decoration: const InputDecoration(labelText: 'Организация'),
            enabled: _editable,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: summaryController,
            decoration: const InputDecoration(labelText: 'Краткое описание'),
            enabled: _editable,
            maxLines: 2,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: descriptionController,
            decoration: const InputDecoration(labelText: 'Полное описание'),
            enabled: _editable,
            maxLines: 4,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: requirementsController,
            decoration: const InputDecoration(labelText: 'Требования'),
            enabled: _editable,
            maxLines: 3,
            onChanged: (_) => onChanged(),
          ),
          DropdownButtonFormField<VacancyEmploymentType?>(
            key: ValueKey('employment-$employmentType'),
            initialValue: employmentType,
            decoration: const InputDecoration(labelText: 'Формат занятости'),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('— не указано —'),
              ),
              ...VacancyEmploymentType.values.map(
                (e) => DropdownMenuItem(value: e, child: Text(e.labelRu)),
              ),
            ],
            onChanged: !_editable ? null : onEmploymentTypeChanged,
          ),
          DropdownButtonFormField<VacancyWorkFormat?>(
            key: ValueKey('format-$workFormat'),
            initialValue: workFormat,
            decoration: const InputDecoration(
              labelText: 'Местоположение / удалённо',
            ),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('— не указано —'),
              ),
              ...VacancyWorkFormat.values.map(
                (e) => DropdownMenuItem(value: e, child: Text(e.labelRu)),
              ),
            ],
            onChanged: !_editable ? null : onWorkFormatChanged,
          ),
          TextField(
            controller: locationController,
            decoration: const InputDecoration(
              labelText: 'Местоположение (текст)',
            ),
            enabled: _editable,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: salaryController,
            decoration: const InputDecoration(labelText: 'Зарплата (optional)'),
            enabled: _editable,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: urlController,
            decoration: const InputDecoration(labelText: 'Ссылка'),
            enabled: _editable,
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 8),
          Text(
            'Контакты',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          TextField(
            controller: contactEmailController,
            decoration: const InputDecoration(labelText: 'Email'),
            enabled: _editable,
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: contactPhoneController,
            decoration: const InputDecoration(labelText: 'Телефон'),
            enabled: _editable,
            keyboardType: TextInputType.phone,
            onChanged: (_) => onChanged(),
          ),
          TextField(
            controller: contactTelegramController,
            decoration: const InputDecoration(labelText: 'Telegram'),
            enabled: _editable,
            onChanged: (_) => onChanged(),
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
                    expiresAt == null
                        ? '— не указан —'
                        : vacancyExpiresLabel(expiresAt!) ??
                              expiresAt!.toLocal().toString(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: !_editable || busy ? null : onPickExpiresAt,
                child: const Text('Выбрать'),
              ),
              if (expiresAt != null)
                IconButton(
                  tooltip: 'Очистить',
                  onPressed: !_editable || busy
                      ? null
                      : () => onExpiresAtChanged(null),
                  icon: const Icon(Icons.clear),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (selected.origin == ContentOrigin.userSubmission ||
              selected.origin == ContentOrigin.importSource)
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Источник'),
              child: Text(selected.origin.labelRu),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('audience-$audienceMode'),
            initialValue: audienceMode,
            decoration: const InputDecoration(labelText: 'Аудитория'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Все')),
              DropdownMenuItem(value: 'groups', child: Text('Группы')),
              DropdownMenuItem(value: 'users', child: Text('Пользователи')),
              DropdownMenuItem(
                value: 'groups_and_users',
                child: Text('Группы и пользователи'),
              ),
            ],
            onChanged: !_editable
                ? null
                : (value) {
                    if (value != null) onAudienceModeChanged(value);
                  },
          ),
          ContentAudienceSelectors(
            studentsRepository: studentsRepository,
            audienceMode: audienceMode,
            selectedGroupIds: groupIds,
            selectedUserIds: userIds,
            enabled: _editable,
            onChanged: onAudienceChanged,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : onPreviewAudience,
            icon: const Icon(Icons.preview_outlined),
            label: const Text('Preview аудитории'),
          ),
          if (audiencePreview != null) ...[
            const SizedBox(height: 8),
            Text(
              'Получателей: ${audiencePreview!.recipientCount}. '
              'Групп: ${audiencePreview!.groupCount}. '
              'Явных пользователей: ${audiencePreview!.explicitUserCount}.',
            ),
          ],
          const SizedBox(height: 16),
          if (onBeginEdit != null && !editingWorkingDraft)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton.icon(
                onPressed: busy ? null : onBeginEdit,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Редактировать'),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canPublish && selected.status == VacancyStatus.approved)
                FilledButton.tonal(
                  onPressed: busy ? null : onPublish,
                  child: const Text('Опубликовать'),
                ),
              if (canModerate && selected.status == VacancyStatus.submitted)
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => onModerate('take_in_moderation'),
                  child: const Text('На модерацию'),
                ),
              if (canModerate && selected.status == VacancyStatus.inModeration)
                FilledButton.tonal(
                  onPressed: busy ? null : () => onModerate('approve'),
                  child: const Text('Одобрить'),
                ),
              if (canModerate &&
                  (selected.status == VacancyStatus.submitted ||
                      selected.status == VacancyStatus.inModeration))
                OutlinedButton(
                  onPressed: busy ? null : () => onModerate('reject'),
                  child: const Text('Отклонить'),
                ),
              if (canPublish && selected.status == VacancyStatus.published)
                OutlinedButton(
                  onPressed: busy ? null : () => onLifecycle('unpublish'),
                  child: const Text('Снять с публикации'),
                ),
              if (canPublish && selected.status == VacancyStatus.published)
                OutlinedButton(
                  onPressed: busy ? null : () => onLifecycle('expire'),
                  child: const Text('Истекла'),
                ),
              if (canPublish && selected.status != VacancyStatus.archived)
                OutlinedButton(
                  onPressed: busy ? null : () => onLifecycle('archive'),
                  child: const Text('В архив'),
                ),
              if (canPublish && selected.status == VacancyStatus.archived)
                OutlinedButton.icon(
                  onPressed: busy ? null : onSafeDelete,
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Удалить навсегда'),
                ),
              if (canWrite && selected.origin == ContentOrigin.demo)
                OutlinedButton.icon(
                  onPressed: busy ? null : onPromoteDemo,
                  icon: const Icon(Icons.upgrade_outlined),
                  label: const Text('Сделать обычной'),
                ),
              if (canWrite && (draftOnly || editingWorkingDraft)) ...[
                OutlinedButton.icon(
                  onPressed: busy ? null : onUploadLogo,
                  icon: const Icon(Icons.apartment_outlined),
                  label: const Text('Логотип'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onUploadCover,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Обложка'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onUploadBackground,
                  icon: const Icon(Icons.wallpaper_outlined),
                  label: const Text('Фон'),
                ),
                TextButton(
                  onPressed: busy ? null : onClearLogo,
                  child: const Text('Убрать логотип'),
                ),
                TextButton(
                  onPressed: busy ? null : onClearCover,
                  child: const Text('Убрать обложку'),
                ),
                TextButton(
                  onPressed: busy ? null : onClearBackground,
                  child: const Text('Убрать фон'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onUploadAsset,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Загрузить вложение'),
                ),
              ],
            ],
          ),
          if (selected.assetIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Вложения: ${selected.assetIds.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (moderationJournal.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Журнал модерации',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            for (final entry in moderationJournal.take(8))
              Text(
                '${entry.action}'
                '${entry.fromStatus != null ? ' (${entry.fromStatus}→${entry.toStatus})' : ''}'
                '${entry.reasonText.isNotEmpty ? ': ${entry.reasonText}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
          if (versions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Версии: ${versions.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (openReports.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Открытые жалобы (${openReports.length})',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            for (final report in openReports.take(5))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  report.vacancyTitle ?? report.vacancyId,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                subtitle: Text('${report.reasonCode} · ${report.status}'),
                trailing: canModerate
                    ? Wrap(
                        spacing: 4,
                        children: [
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => onResolveReport(report, 'resolve'),
                            child: const Text('Resolve'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => onResolveReport(report, 'reject'),
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
              'Публикация доступна только после одобрения модерацией (approved).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          ContentTechnicalPanel(
            children: [
              if (selected.origin != ContentOrigin.userSubmission &&
                  selected.origin != ContentOrigin.importSource)
                DropdownButtonFormField<String>(
                  key: ValueKey('origin-$origin'),
                  initialValue: origin,
                  decoration: const InputDecoration(labelText: 'origin'),
                  items: const [
                    DropdownMenuItem(value: 'admin', child: Text('admin')),
                    DropdownMenuItem(value: 'demo', child: Text('demo')),
                  ],
                  onChanged: !_editable
                      ? null
                      : (value) {
                          if (value != null) onOriginChanged(value);
                        },
                ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('row_version'),
                subtitle: Text('${selected.rowVersion}'),
              ),
              if (selected.legacyKey != null)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('legacy_key'),
                  subtitle: Text(selected.legacyKey!),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
