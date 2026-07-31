import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../academic/students/students_repository.dart';
import '../reference/content_media_store.dart';
import '../shared/admin_content_backend.dart';
import '../shared/content_action_model.dart';
import '../shared/content_action_picker.dart';
import '../shared/content_card_variant_picker.dart';
import '../shared/content_color_field.dart';
import '../shared/content_color_utils.dart';
import '../shared/content_icon_picker.dart';
import '../shared/content_preview_binder.dart';
import '../shared/content_preview_mode.dart';
import '../shared/content_media_intent.dart';
import '../shared/content_technical_panel.dart';
import '../shared/phone_preview_frame.dart';
import '../shared/visual_editor_list_panel.dart';
import '../shared/visual_editor_shell.dart';
import '../shared/visual_editor_states.dart';
import 'content_audience_selectors.dart';
import 'profile_feed_item.dart';
import 'profile_feed_preview.dart';
import 'profile_feed_repository.dart';
import 'supabase_profile_feed_repository.dart';

/// Admin visual editor for managed Profile feed (`profile_feed_card_v1`).
class ProfileFeedEditorScreen extends StatefulWidget {
  const ProfileFeedEditorScreen({
    super.key,
    this.repository,
    this.session,
    this.mediaStore,
  });

  final ProfileFeedRepository? repository;
  final AdminSessionController? session;
  final ContentMediaStore? mediaStore;

  @override
  State<ProfileFeedEditorScreen> createState() =>
      _ProfileFeedEditorScreenState();
}

class _ProfileFeedEditorScreenState extends State<ProfileFeedEditorScreen> {
  late final ProfileFeedRepository _repository =
      widget.repository ?? _defaultRepo();
  late final StudentsRepository _studentsRepository = _defaultStudentsRepo();
  ContentMediaStore? get _mediaStore {
    if (widget.mediaStore != null) return widget.mediaStore;
    if (AdminBackendConfig.isDemoMode) return null;
    final client = _tryClient();
    if (client == null) return null;
    return ContentMediaStore(client: client);
  }

  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  final _ctaLabelController = TextEditingController();
  final _ctaRouteController = TextEditingController();
  final _ctaUrlController = TextEditingController();
  final _sortOrderController = TextEditingController(text: '0');
  final _priorityController = TextEditingController(text: '0');
  final _iconController = TextEditingController(text: 'info');
  final _gradientAController = TextEditingController(text: '#DCD0FA');
  final _gradientBController = TextEditingController(text: '#C9B8F3');

  List<ProfileFeedItem> _items = [];
  String? _selectedId;
  VisualEditorListTab _listTab = VisualEditorListTab.published;
  bool _showDemoOnly = false;
  bool _loading = true;
  bool _busy = false;
  bool _deleting = false;
  bool _dirty = false;
  bool _editingWorkingDraft = false;
  bool _suppressTabCallback = false;
  bool _imageUploading = false;
  String _audienceMode = 'all';
  List<String> _groupIds = const [];
  List<String> _userIds = const [];
  DateTime? _startsAt;
  DateTime? _endsAt;
  ProfileFeedAudiencePreview? _audiencePreview;
  String? _banner;
  String? _loadError;
  String _ctaAction = 'route';
  int _gradientDirection = 45;
  ContentCardVariant _cardVariant = ContentCardVariant.gradientText;
  ContentPreviewMode _previewMode = ContentPreviewMode.effectiveDraft;

  final Map<String, ContentMediaIntentState> _imageIntent = {};
  ProfileFeedItem? _boundItem;

  ProfileFeedAdminListPartitions get _partitions =>
      partitionAdminProfileFeed(_items);

  VisualEditorTabCounts get _tabCounts => VisualEditorTabCounts(
    published: _partitions.published.length,
    drafts: _partitions.drafts.length,
    archived: _partitions.archived.length,
  );

  List<ProfileFeedItem> get _tabItems {
    final parts = _partitions;
    final base = switch (_listTab) {
      VisualEditorListTab.published => parts.published,
      VisualEditorListTab.drafts => parts.drafts,
      VisualEditorListTab.archived => parts.archived,
    };
    if (!_showDemoOnly) return base;
    return base.where((e) => e.origin == ContentOrigin.demo).toList();
  }

  ProfileFeedItem? get _selected {
    if (_selectedId == null) return null;
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  bool get _canWrite => widget.session?.capabilities.canWriteContent ?? true;

  bool get _canPublish =>
      widget.session?.capabilities.canPublishContent ?? true;

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  ProfileFeedRepository _defaultRepo() {
    return AdminContentBackend.resolveRepository<ProfileFeedRepository>(
      isDemoMode: AdminBackendConfig.isDemoMode,
      client: _tryClient(),
      localFactory: LocalProfileFeedRepository.new,
      supabaseFactory: (client) =>
          SupabaseProfileFeedRepository(client: client),
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
  }

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    _ctaLabelController.dispose();
    _ctaRouteController.dispose();
    _ctaUrlController.dispose();
    _sortOrderController.dispose();
    _priorityController.dispose();
    _iconController.dispose();
    _gradientAController.dispose();
    _gradientBController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final items = await _repository.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _loadError = null;
        _ensureSelectionForTab();
      });
      _syncControllers();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            'Не удалось загрузить ленту профиля. Попробуйте обновить страницу.';
      });
    }
  }

  void _syncControllers() {
    final selected = _selected;
    _titleController.value = TextEditingValue(
      text: selected?.payload.title ?? '',
      selection: TextSelection.collapsed(
        offset: (selected?.payload.title ?? '').length,
      ),
    );
    _subtitleController.value = TextEditingValue(
      text: selected?.payload.subtitle ?? '',
      selection: TextSelection.collapsed(
        offset: (selected?.payload.subtitle ?? '').length,
      ),
    );
    _ctaLabelController.value = TextEditingValue(
      text: selected?.payload.ctaLabel ?? '',
      selection: TextSelection.collapsed(
        offset: (selected?.payload.ctaLabel ?? '').length,
      ),
    );
    _ctaRouteController.text = selected?.payload.ctaRoute ?? '';
    _ctaUrlController.text = selected?.payload.ctaUrl ?? '';
    _sortOrderController.text = '${selected?.sortOrder ?? 0}';
    _priorityController.text = '${selected?.priority ?? 0}';
    final payload = selected?.payload;
    _iconController.text = payload?.iconKey ?? 'info';
    final gradient = payload?.gradientColors;
    _gradientAController.text = formatContentHexColor(
      gradient?.first ?? const Color(0xFFDCD0FA),
    );
    _gradientBController.text = formatContentHexColor(
      gradient != null && gradient.length > 1
          ? gradient[1]
          : (gradient?.first ?? const Color(0xFFC9B8F3)),
    );
    _gradientDirection = payload?.gradientAngle ?? 45;
    _cardVariant =
        ContentCardVariant.fromKey(payload?.cardVariant) ??
        ContentCardVariant.gradientText;
    _ctaAction =
        (selected?.payload.ctaUrl != null &&
            selected!.payload.ctaUrl!.isNotEmpty)
        ? 'url'
        : 'route';
    if (selected?.payload.action != null) {
      final fromWire = contentActionFromWire(selected!.payload.action);
      applyContentActionToLegacy(
        action: fromWire,
        onCtaActionChanged: (value) => _ctaAction = value,
        onCtaRouteChanged: (value) => _ctaRouteController.text = value,
        onCtaUrlChanged: (value) => _ctaUrlController.text = value,
      );
    }
    _audienceMode = selected?.audienceMode ?? 'all';
    _groupIds = selected?.audienceGroupIds ?? const [];
    _userIds = selected?.audienceUserIds ?? const [];
    _startsAt = selected?.startsAt;
    _endsAt = selected?.endsAt;
    _audiencePreview = null;
    _boundItem = selected?.copyWith();
    if (selected != null) {
      _imageIntent.putIfAbsent(
        selected.id,
        () => ContentMediaIntentState(assetId: selected.payload.imageAssetId),
      );
    }
  }

  void _discardLocalChanges() {
    final bound = _boundItem;
    if (bound == null) return;
    setState(() {
      _replaceItem(bound);
      _dirty = false;
      _imageIntent[bound.id] = ContentMediaIntentState(
        assetId: bound.payload.imageAssetId,
      );
    });
    _syncControllers();
  }

  void _replaceItem(ProfileFeedItem item) {
    final index = _items.indexWhere((e) => e.id == item.id);
    if (index >= 0) _items[index] = item;
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
    ProfileFeedItem? item;
    for (final candidate in _items) {
      if (candidate.id == id) {
        item = candidate;
        break;
      }
    }
    setState(() {
      _selectedId = id;
      _editingWorkingDraft = false;
      if (item != null) {
        _listTab = switch (item.status) {
          ProfileFeedStatus.published => VisualEditorListTab.published,
          ProfileFeedStatus.draft => VisualEditorListTab.drafts,
          ProfileFeedStatus.archived => VisualEditorListTab.archived,
        };
      }
    });
    _syncControllers();
  }

  Future<void> _beginEdit() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _runGuarded(() async {
      final item = await _repository.beginEdit(selected.id);
      if (!mounted) return;
      setState(() {
        _replaceItem(item);
        _editingWorkingDraft = true;
      });
      _syncControllers();
    });
  }

  Future<void> _discardWorkingDraft() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _runGuarded(() async {
      final item = await _repository.discardWorkingDraft(selected.id);
      if (!mounted) return;
      setState(() {
        _editingWorkingDraft = false;
        _replaceItem(item);
      });
      _syncControllers();
      _snack('Изменения отменены');
    });
  }

  void _selectNextAfterRemoval(String removedId, List<ProfileFeedItem> before) {
    final index = before.indexWhere((e) => e.id == removedId);
    final remaining = before.where((e) => e.id != removedId).toList();
    if (remaining.isEmpty) {
      _selectedId = null;
      return;
    }
    if (index >= 0 && index < remaining.length) {
      _selectedId = remaining[index].id;
    } else {
      _selectedId = remaining.last.id;
    }
  }

  ProfileFeedPayload? _draftPayload() {
    final actionSelection = contentActionFromLegacy(
      ctaAction: _ctaAction,
      ctaRoute: _ctaRouteController.text,
      ctaUrl: _ctaUrlController.text,
    );
    final map = <String, dynamic>{
      'title': _titleController.text.trim(),
      'subtitle': _subtitleController.text.trim(),
      'cta_label': _ctaLabelController.text.trim(),
      'icon_key': _iconController.text.trim(),
      'gradient_colors': [
        _gradientAController.text.trim(),
        _gradientBController.text.trim(),
      ],
      'card_variant': _cardVariant.key,
      'gradient_angle': _gradientDirection,
      'action': contentActionToWire(actionSelection),
      if (_ctaAction == 'route' && _ctaRouteController.text.trim().isNotEmpty)
        'cta_route': _ctaRouteController.text.trim(),
      if (_ctaAction == 'url' && _ctaUrlController.text.trim().isNotEmpty)
        'cta_url': _ctaUrlController.text.trim(),
    };
    final parsed = ProfileFeedPayload.tryParse(map);
    if (parsed == null) return null;
    final existing = _selected?.payload;
    return parsed.copyWith(
      imageAssetId: existing?.imageAssetId,
      iconAssetId: existing?.iconAssetId,
      bgMode: existing?.bgMode,
      bgColor: existing?.bgColor,
      overlayOpacity: existing?.overlayOpacity,
    );
  }

  void _syncPayloadFromEditors() {
    final payload = _draftPayload();
    if (payload == null) return;
    _updateSelected(
      (item) => item.copyWith(title: payload.title, payload: payload),
    );
  }

  void _updateSelected(ProfileFeedItem Function(ProfileFeedItem item) update) {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      _replaceItem(update(selected));
      _dirty = true;
    });
  }

  void _showBanner(String message) => setState(() => _banner = message);

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<T?> _runGuarded<T>(Future<T> Function() action) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      return await action();
    } on ProfileFeedRepositoryException catch (error) {
      _showBanner(error.message);
      return null;
    } catch (_) {
      _showBanner('Не удалось выполнить операцию. Попробуйте ещё раз.');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    if (!_canWrite) {
      _showBanner('Недостаточно прав для создания карточек.');
      return;
    }
    await _runGuarded(() async {
      final defaultPayload = ProfileFeedPayload.tryParse({
        'title': 'Новая карточка',
        'subtitle': 'Краткое описание',
        'cta_label': 'Открыть',
        'icon_key': 'info',
        'gradient_colors': ['#DCD0FA', '#C9B8F3'],
        'card_variant': ContentCardVariant.gradientText.key,
        'gradient_angle': 45,
        'cta_route': '/profile',
        'action': contentActionToWire(
          const ContentActionSelection(
            kind: ContentActionKind.appScreen,
            screenKey: 'profile',
          ),
        ),
      });
      final created = await _repository.createDraft(payload: defaultPayload);
      if (!mounted) return;
      _suppressTabCallback = true;
      setState(() {
        _items = [..._items, created];
        _listTab = VisualEditorListTab.drafts;
        _selectedId = created.id;
        _dirty = false;
        _editingWorkingDraft = false;
      });
      _syncControllers();
      _snack('Черновик создан');
      // SegmentedButton can emit a stale published selection when tab counts
      // change; re-assert draft selection after that callback settles.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _listTab = VisualEditorListTab.drafts;
            _selectedId = created.id;
            _suppressTabCallback = false;
          });
          _syncControllers();
        });
      });
    });
  }

  Future<void> _duplicate() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _runGuarded(() async {
      final copy = await _repository.duplicate(selected.id);
      if (!mounted) return;
      setState(() {
        _items = [..._items, copy];
        _listTab = VisualEditorListTab.drafts;
        _selectedId = copy.id;
        _dirty = false;
      });
      _syncControllers();
      _snack('Создана копия');
    });
  }

  Future<ProfileFeedItem?> _saveSelected() async {
    final selected = _selected;
    if (selected == null) return null;
    final payload = _draftPayload();
    if (payload == null) {
      throw const ProfileFeedRepositoryException(
        'Проверьте поля карточки (заголовок, подзаголовок, CTA).',
      );
    }
    var nextPayload = payload;
    final intent =
        _imageIntent[selected.id] ?? ContentMediaIntentState.untouched;
    final store = _mediaStore;
    if (intent.hasLocalPick && store != null) {
      setState(() => _imageUploading = true);
      try {
        final bytes = intent.localBytes;
        if (bytes == null || bytes.isEmpty) {
          throw const ProfileFeedRepositoryException(
            'Локальное изображение не найдено.',
          );
        }
        final assetId = await store.uploadBytes(
          contentItemId: selected.id,
          bytes: bytes,
          contentType: 'image/png',
          title: payload.title,
        );
        nextPayload = payload.copyWith(imageAssetId: assetId);
      } finally {
        if (mounted) setState(() => _imageUploading = false);
      }
    } else if (intent.shouldOmitAssetOnSave) {
      nextPayload = payload.copyWith(clearImageAssetId: true);
    }

    var next = selected.copyWith(
      title: nextPayload.title,
      payload: nextPayload,
      priority:
          int.tryParse(_priorityController.text.trim()) ?? selected.priority,
      startsAt: _startsAt,
      endsAt: _endsAt,
      clearStartsAt: _startsAt == null,
      clearEndsAt: _endsAt == null,
      sortOrder:
          int.tryParse(_sortOrderController.text.trim()) ?? selected.sortOrder,
      audienceMode: _audienceMode,
      audienceGroupIds: _groupIds,
      audienceUserIds: _userIds,
    );
    if (_editingWorkingDraft) {
      final draftVersion = selected.workingDraftRowVersion;
      if (draftVersion == null) {
        throw const ProfileFeedRepositoryException(
          'Черновик изменений не найден.',
        );
      }
      next = await _repository.saveWorkingDraft(
        next,
        expectedDraftRowVersion: draftVersion,
      );
      if (!mounted) return next;
      setState(() {
        _replaceItem(next);
        _dirty = false;
        _audiencePreview = null;
        _imageIntent[next.id] = ContentMediaIntentState(
          assetId: next.payload.imageAssetId,
        );
      });
      _syncControllers();
      return next;
    }
    next = await _repository.updateDraft(next);
    next = await _repository.setPlacements(
      id: next.id,
      sortOrder:
          int.tryParse(_sortOrderController.text.trim()) ?? next.sortOrder,
      expectedRowVersion: next.rowVersion,
    );
    if (_audienceDirty(selected)) {
      next = await _repository.setAudience(
        id: next.id,
        audienceMode: _audienceMode,
        groupIds: _groupIds,
        userIds: _userIds,
        expectedRowVersion: next.rowVersion,
      );
    }
    if (!mounted) return next;
    setState(() {
      _replaceItem(next);
      _dirty = false;
      _audiencePreview = null;
      _imageIntent[next.id] = ContentMediaIntentState(
        assetId: next.payload.imageAssetId,
      );
    });
    _syncControllers();
    return next;
  }

  bool _audienceDirty(ProfileFeedItem selected) {
    if (selected.audienceMode != _audienceMode) return true;
    if (!_sameIdSet(selected.audienceGroupIds, _groupIds)) return true;
    if (!_sameIdSet(selected.audienceUserIds, _userIds)) return true;
    return false;
  }

  bool _sameIdSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    return {...a}.containsAll(b);
  }

  Future<void> _saveDraft() async {
    if (!_canWrite) {
      _showBanner('Недостаточно прав для сохранения.');
      return;
    }
    await _runGuarded(() async {
      final saved = await _saveSelected();
      if (saved != null) _snack('Черновик сохранён');
    });
  }

  Future<void> _publish() async {
    final selected = _selected;
    if (selected == null || !_canPublish) return;
    await _runGuarded(() async {
      var current = selected;
      if (_dirty) {
        final saved = await _saveSelected();
        if (saved == null) return;
        current = saved;
      }
      if (_editingWorkingDraft) {
        final draftVersion = current.workingDraftRowVersion;
        if (draftVersion == null) {
          _showBanner('Черновик изменений не найден.');
          return;
        }
        final published = await _repository.publishWorkingDraft(
          current.id,
          expectedDraftRowVersion: draftVersion,
        );
        if (!mounted) return;
        setState(() {
          _editingWorkingDraft = false;
          _replaceItem(published);
        });
        _syncControllers();
        _snack('Изменения опубликованы');
        return;
      }
      final published = await _repository.publish(
        current.id,
        current.rowVersion,
      );
      if (!mounted) return;
      setState(() => _replaceItem(published));
      _snack('Карточка опубликована');
    });
  }

  Future<void> _unpublish() async {
    final selected = _selected;
    if (selected == null || !_canPublish) return;
    await _runGuarded(() async {
      final updated = await _repository.unpublish(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() => _replaceItem(updated));
      _snack('Публикация снята');
    });
  }

  Future<void> _archive() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Отправить в архив?'),
        content: Text('«${selected.title}» скроется из ленты профиля.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('В архив'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final before = List<ProfileFeedItem>.from(_tabItems);
    await _runGuarded(() async {
      final updated = await _repository.archive(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() {
        _replaceItem(updated);
        _selectNextAfterRemoval(updated.id, before);
      });
      _syncControllers();
      _snack('Карточка в архиве');
    });
  }

  Future<void> _restoreArchived() async {
    final selected = _selected;
    if (selected == null || !selected.isArchived || !_canWrite) return;
    await _runGuarded(() async {
      final updated = await _repository.restoreArchived(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() {
        _replaceItem(updated);
        _listTab = VisualEditorListTab.drafts;
        _selectedId = updated.id;
      });
      _syncControllers();
      _snack('Карточка восстановлена как черновик');
    });
  }

  Future<void> _safeDelete() async {
    final selected = _selected;
    if (selected == null || !selected.isArchived || !_canPublish) return;
    if (_deleting || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить карточку навсегда?'),
        content: const Text(
          'Карточку и её версии восстановить будет нельзя. '
          'Демо-идентификатор будет помечен как удалённый.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Удалить навсегда'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final before = List<ProfileFeedItem>.from(_tabItems);
    final removedId = selected.id;
    setState(() {
      _deleting = true;
      _busy = true;
      _banner = null;
    });
    try {
      await _repository.safeDelete(removedId, selected.rowVersion);
      if (!mounted) return;
      setState(() {
        _items = _items.where((e) => e.id != removedId).toList();
        _selectNextAfterRemoval(removedId, before);
        _dirty = false;
      });
      _syncControllers();
      _snack('Карточка удалена');
    } on ProfileFeedRepositoryException catch (error) {
      _showBanner(error.message);
    } catch (_) {
      _showBanner('Не удалось удалить карточку. Попробуйте ещё раз.');
    } finally {
      if (mounted) {
        setState(() {
          _deleting = false;
          _busy = false;
        });
      }
    }
  }

  Future<void> _promoteDemo() async {
    final selected = _selected;
    if (selected == null ||
        selected.origin != ContentOrigin.demo ||
        !_canWrite) {
      return;
    }
    await _runGuarded(() async {
      final updated = await _repository.promoteDemo(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() => _replaceItem(updated));
      _snack('Демо-карточка переведена в управляемый контент');
    });
  }

  Future<void> _move(int delta) async {
    if (_listTab == VisualEditorListTab.archived) return;
    final selected = _selected;
    if (selected == null) return;
    final tabItems = List<ProfileFeedItem>.from(_tabItems);
    final index = tabItems.indexWhere((e) => e.id == selected.id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= tabItems.length) return;
    final moved = tabItems.removeAt(index);
    tabItems.insert(target, moved);
    final otherIds = _items
        .where((e) => !tabItems.any((t) => t.id == e.id))
        .map((e) => e.id)
        .toList();
    final orderedIds = [...tabItems.map((e) => e.id), ...otherIds];
    setState(() {
      for (var i = 0; i < orderedIds.length; i++) {
        final itemIndex = _items.indexWhere((e) => e.id == orderedIds[i]);
        if (itemIndex >= 0) {
          _items[itemIndex] = _items[itemIndex].copyWith(sortOrder: i);
        }
      }
      _items.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    });
    await _runGuarded(() async {
      await _repository.reorder(
        tabItems.map((e) => e.id).toList(),
        tabItems.map((e) => e.rowVersion).toList(),
      );
    });
  }

  Future<void> _pickImage() async {
    final selected = _selected;
    if (selected == null ||
        !(selected.isDraft || _editingWorkingDraft) ||
        !_canWrite) {
      return;
    }
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = picked?.files.single;
    final bytes = file?.bytes;
    if (bytes == null || bytes.isEmpty) return;
    setState(() {
      _imageIntent[selected.id] =
          (_imageIntent[selected.id] ?? ContentMediaIntentState.untouched)
              .pickLocal(bytes);
      _dirty = true;
    });
  }

  Future<void> _clearImage() async {
    final selected = _selected;
    if (selected == null) return;
    setState(() {
      _imageIntent[selected.id] =
          (_imageIntent[selected.id] ?? ContentMediaIntentState.untouched)
              .markRemoved();
      _dirty = true;
    });
    _updateSelected(
      (item) => item.copyWith(
        payload: item.payload.copyWith(clearImageAssetId: true),
      ),
    );
  }

  Future<void> _previewAudience() async {
    final selected = _selected;
    if (selected == null) return;
    if (_dirty || _audienceDirty(selected)) {
      _showBanner('Сначала сохраните черновик с актуальной аудиторией.');
      return;
    }
    await _runGuarded(() async {
      final preview = await _repository.previewAudience(selected.id);
      if (!mounted) return;
      setState(() {
        _audiencePreview = preview;
        _banner =
            'Preview аудитории: ${preview.recipientCount} получателей '
            '(групп: ${preview.groupCount}; '
            'явных пользователей: ${preview.explicitUserCount}).';
      });
    });
  }

  Future<void> _showVersions() async {
    final selected = _selected;
    if (selected == null) return;
    final versions = await _runGuarded(
      () => _repository.listVersions(selected.id),
    );
    if (versions == null || !mounted) return;
    if (versions.isEmpty) {
      _snack('История версий пуста');
      return;
    }
    final restore = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _VersionHistoryDialog(versions: versions),
    );
    if (restore == null) return;
    await _runGuarded(() async {
      final restored = await _repository.restoreVersion(
        selected.id,
        restore,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() {
        _replaceItem(restored);
        _dirty = false;
      });
      _syncControllers();
      _snack('Версия $restore восстановлена');
    });
  }

  Future<void> _pickDate({required bool starts}) async {
    final initial = (starts ? _startsAt : _endsAt) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
    );
    if (date == null) return;
    setState(() {
      if (starts) {
        _startsAt = date;
      } else {
        _endsAt = date;
      }
      _dirty = true;
    });
  }

  List<ManagedProfileFeedCard> _previewCarouselCards() {
    var cards = [
      for (final item in _partitions.publishedPreviewItems)
        item.toManagedCard(showDemoBadge: false),
    ];
    final selected = _selected;
    if (selected == null) return cards;

    if (_previewMode == ContentPreviewMode.publishedCanonical) {
      return cards;
    }

    if (!shouldOverlayLiveDraft(
      isDraft: selected.isDraft,
      editingWorkingDraft: _editingWorkingDraft,
      dirty: _dirty,
      mode: _previewMode,
    )) {
      return cards;
    }

    final payload = _draftPayload();
    if (payload == null) return cards;

    final intent =
        _imageIntent[selected.id] ?? ContentMediaIntentState.untouched;
    final overlay = selected
        .copyWith(title: payload.title, payload: payload)
        .toManagedCard(showDemoBadge: selected.origin == ContentOrigin.demo)
        .copyWith(
          imageBytes: intent.bytesForPreview,
          imageLoading: intent.phase == ContentMediaPhase.uploading,
        );
    final index = cards.indexWhere((card) => card.id == selected.id);
    if (index >= 0) {
      cards = [...cards]..[index] = overlay;
      return cards;
    }

    cards = [...cards, overlay];
    cards.sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      if (byOrder != 0) return byOrder;
      return b.priority.compareTo(a.priority);
    });
    return cards;
  }

  Future<void> _confirmDiscard() async {
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const VisualEditorLoadingState();
    if (_loadError != null) {
      return VisualEditorErrorState(
        message: _loadError!,
        onRetry: () {
          setState(() => _loading = true);
          _bootstrap();
        },
      );
    }

    final selected = _selected;
    final previewCards = _previewCarouselCards();
    final previewPayload =
        _draftPayload() ??
        selected?.payload ??
        ProfileFeedPayload.demoFeed.first;
    final v2PublishBlocked = contentWireUsesV2PublishFeatures(
      previewPayload.toWireJson(),
    );

    return VisualEditorShell(
      title: 'Визуальный редактор ленты профиля',
      selectedTitle: selected?.title,
      statusChip: selected?.status.russianLabel,
      originDemoBadge: selected?.origin == ContentOrigin.demo,
      dirty: _dirty,
      busy: _busy || _imageUploading,
      banner: _banner,
      defaultInfoMessage: v2PublishBlocked
          ? kVisualStudioV2PublishBlockedMessageRu
          : 'Карточки ленты профиля. Новости сюда не копируются.',
      canWrite: _canWrite,
      canPublish: _canPublish && selected != null && !selected.isArchived,
      canUnpublish: _canPublish,
      listTab: _listTab,
      tabCounts: _tabCounts,
      onTabChanged: (tab) {
        if (_busy || _suppressTabCallback || tab == _listTab) return;
        setState(() {
          _listTab = tab;
          _editingWorkingDraft = false;
          _ensureSelectionForTab();
        });
        _syncControllers();
      },
      onCreate: _canWrite ? _create : null,
      onSaveDraft:
          _canWrite && (selected?.isDraft == true || _editingWorkingDraft)
          ? _saveDraft
          : null,
      onPublish: _publish,
      onUnpublish: _unpublish,
      onVersions: _showVersions,
      onPopDirtyConfirm: _confirmDiscard,
      editingWorkingDraft: _editingWorkingDraft,
      onDiscardWorkingDraft: _editingWorkingDraft && _canWrite
          ? _discardWorkingDraft
          : null,
      onDiscardLocalChanges: _dirty && _canWrite ? _discardLocalChanges : null,
      listBuilder: (context) => VisualEditorListPanel(
        panelTitle: 'Карточки ленты',
        tab: _listTab,
        tabCounts: _tabCounts,
        items: [
          for (final item in _tabItems)
            VisualEditorListItem(
              id: item.id,
              title: item.title,
              subtitle: item.payload.subtitle,
              isDemo: item.origin == ContentOrigin.demo,
              statusLabel: item.status.russianLabel,
              leading: CircleAvatar(
                backgroundColor: const Color(0xFFDCD0FA),
                child: Text(
                  '${item.sortOrder + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF4C1D95),
                  ),
                ),
              ),
            ),
        ],
        selectedId: _selectedId,
        onTabChanged: (tab) {
          if (_busy || _suppressTabCallback || tab == _listTab) return;
          setState(() {
            _listTab = tab;
            _editingWorkingDraft = false;
            _ensureSelectionForTab();
          });
          _syncControllers();
        },
        onSelected: _select,
        onMove: _move,
        onCreate: _canWrite ? _create : null,
        showDemoOnly: _showDemoOnly,
        onDemoFilterChanged: (value) => setState(() => _showDemoOnly = value),
      ),
      previewBuilder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ContentPreviewModeToggle(
            mode: _previewMode,
            onChanged: (mode) => setState(() => _previewMode = mode),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _ProfileFeedPhonePreview(
              cards: previewCards,
              selectedId: _selectedId,
              onCardTap: (card) => _select(card.id),
              onVisibleCard: (card) {
                if (_listTab != VisualEditorListTab.published) return;
                if (_editingWorkingDraft) return;
                if (_selectedId != card.id) _select(card.id);
              },
            ),
          ),
        ],
      ),
      propertiesBuilder: (context) => selected == null
          ? VisualEditorEmptyState(
              message: _tabItems.isEmpty
                  ? _listTab.emptyMessageRu
                  : 'Выберите карточку',
              actionLabel: _canWrite && _tabItems.isEmpty ? 'Создать' : null,
              onAction: _canWrite && _tabItems.isEmpty ? _create : null,
            )
          : _PropertiesPanel(
              selected: selected,
              canWrite: _canWrite,
              canPublish: _canPublish,
              editingWorkingDraft: _editingWorkingDraft,
              busy: _busy,
              deleting: _deleting,
              imageUploading: _imageUploading,
              mediaAvailable: _mediaStore != null,
              titleController: _titleController,
              subtitleController: _subtitleController,
              ctaLabelController: _ctaLabelController,
              ctaRouteController: _ctaRouteController,
              ctaUrlController: _ctaUrlController,
              ctaAction: _ctaAction,
              iconController: _iconController,
              gradientAController: _gradientAController,
              gradientBController: _gradientBController,
              gradientDirection: _gradientDirection,
              cardVariant: _cardVariant,
              sortOrderController: _sortOrderController,
              priorityController: _priorityController,
              audienceMode: _audienceMode,
              groupIds: _groupIds,
              userIds: _userIds,
              startsAt: _startsAt,
              endsAt: _endsAt,
              audiencePreview: _audiencePreview,
              studentsRepository: _studentsRepository,
              onTitleChanged: (value) => _updateSelected(
                (item) => item.copyWith(
                  title: value,
                  payload: item.payload.copyWith(title: value),
                ),
              ),
              onSubtitleChanged: (value) => _updateSelected(
                (item) => item.copyWith(
                  payload: item.payload.copyWith(subtitle: value),
                ),
              ),
              onCtaLabelChanged: (value) => _updateSelected(
                (item) => item.copyWith(
                  payload: item.payload.copyWith(ctaLabel: value),
                ),
              ),
              onIconChanged: (key) {
                _iconController.text = key ?? '';
                _syncPayloadFromEditors();
              },
              onGradientColorAChanged: (value) {
                _gradientAController.text = value;
                _syncPayloadFromEditors();
              },
              onGradientColorBChanged: (value) {
                _gradientBController.text = value;
                _syncPayloadFromEditors();
              },
              onGradientDirectionChanged: (value) {
                setState(() => _gradientDirection = value);
                _syncPayloadFromEditors();
              },
              onCardVariantChanged: (value) {
                setState(() => _cardVariant = value);
                _syncPayloadFromEditors();
              },
              onActionSelectionChanged: (action) {
                applyContentActionToLegacy(
                  action: action,
                  onCtaActionChanged: (value) => _ctaAction = value,
                  onCtaRouteChanged: (value) {
                    _ctaRouteController.text = value;
                    _updateSelected(
                      (item) => item.copyWith(
                        payload: item.payload.copyWith(
                          ctaRoute: value.trim().isEmpty ? null : value.trim(),
                          clearCtaRoute: value.trim().isEmpty,
                          clearCtaUrl: true,
                          action: contentActionToWire(action),
                        ),
                      ),
                    );
                  },
                  onCtaUrlChanged: (value) {
                    _ctaUrlController.text = value;
                    _updateSelected(
                      (item) => item.copyWith(
                        payload: item.payload.copyWith(
                          ctaUrl: value.trim().isEmpty ? null : value.trim(),
                          clearCtaUrl: value.trim().isEmpty,
                          clearCtaRoute: true,
                          action: contentActionToWire(action),
                        ),
                      ),
                    );
                  },
                );
              },
              onCtaRouteChanged: (value) => _updateSelected(
                (item) => item.copyWith(
                  payload: item.payload.copyWith(
                    ctaRoute: value.trim().isEmpty ? null : value.trim(),
                    clearCtaRoute: value.trim().isEmpty,
                  ),
                ),
              ),
              onCtaUrlChanged: (value) => _updateSelected(
                (item) => item.copyWith(
                  payload: item.payload.copyWith(
                    ctaUrl: value.trim().isEmpty ? null : value.trim(),
                    clearCtaUrl: value.trim().isEmpty,
                  ),
                ),
              ),
              onSortOrderChanged: (_) => setState(() => _dirty = true),
              onPriorityChanged: (_) => setState(() => _dirty = true),
              onAudienceModeChanged: (value) => setState(() {
                _audienceMode = value;
                _audiencePreview = null;
                _dirty = true;
              }),
              onAudienceChanged: ({required groupIds, required userIds}) {
                setState(() {
                  _groupIds = groupIds;
                  _userIds = userIds;
                  _audiencePreview = null;
                  _dirty = true;
                });
              },
              onPickStarts: () => _pickDate(starts: true),
              onPickEnds: () => _pickDate(starts: false),
              onClearSchedule: () => setState(() {
                _startsAt = null;
                _endsAt = null;
                _dirty = true;
              }),
              onPickImage: _pickImage,
              onClearImage: _clearImage,
              onDuplicate: _duplicate,
              onArchive: _archive,
              onRestoreArchived: _restoreArchived,
              onSafeDelete: _safeDelete,
              onPromoteDemo: _promoteDemo,
              onBeginEdit: !selected.isDraft && !selected.isArchived
                  ? _beginEdit
                  : null,
              onPreviewAudience: _previewAudience,
            ),
    );
  }
}

class _ProfileFeedPhonePreview extends StatefulWidget {
  const _ProfileFeedPhonePreview({
    required this.cards,
    required this.selectedId,
    required this.onCardTap,
    required this.onVisibleCard,
  });

  final List<ManagedProfileFeedCard> cards;
  final String? selectedId;
  final ValueChanged<ManagedProfileFeedCard> onCardTap;
  final ValueChanged<ManagedProfileFeedCard> onVisibleCard;

  @override
  State<_ProfileFeedPhonePreview> createState() =>
      _ProfileFeedPhonePreviewState();
}

class _ProfileFeedPhonePreviewState extends State<_ProfileFeedPhonePreview> {
  ManagedProfileFeedCard? _detailCard;

  void _openDetail(ManagedProfileFeedCard card) {
    widget.onCardTap(card);
    setState(() => _detailCard = card);
  }

  @override
  Widget build(BuildContext context) {
    return PhonePreviewFrame(
      child: Theme(
        data: studentPlatformLightTheme(),
        child: SafeArea(
          child: StudentProfileScreenPreview(
            displayName: 'Анна С.',
            groupLabel: 'ВВ-2024',
            universityLabel: 'СПБГАСУ',
            statusLabel: 'студент',
            pointsChip: const StudentPointsSummaryChip(
              summary: StudentPointsSummary(
                userId: 'preview-user',
                balance: 128,
              ),
            ),
            feedCards: widget.cards,
            selectedFeedId: widget.selectedId,
            onFeedVisible: widget.onVisibleCard,
            onFeedTap: _openDetail,
            detailCard: _detailCard,
            onBack: () => setState(() => _detailCard = null),
          ),
        ),
      ),
    );
  }
}

class _PropertiesPanel extends StatelessWidget {
  const _PropertiesPanel({
    required this.selected,
    required this.canWrite,
    required this.canPublish,
    required this.editingWorkingDraft,
    required this.busy,
    required this.deleting,
    required this.imageUploading,
    required this.mediaAvailable,
    required this.titleController,
    required this.subtitleController,
    required this.ctaLabelController,
    required this.ctaRouteController,
    required this.ctaUrlController,
    required this.ctaAction,
    required this.iconController,
    required this.gradientAController,
    required this.gradientBController,
    required this.gradientDirection,
    required this.cardVariant,
    required this.sortOrderController,
    required this.priorityController,
    required this.audienceMode,
    required this.groupIds,
    required this.userIds,
    required this.startsAt,
    required this.endsAt,
    required this.audiencePreview,
    required this.studentsRepository,
    required this.onTitleChanged,
    required this.onSubtitleChanged,
    required this.onCtaLabelChanged,
    required this.onIconChanged,
    required this.onGradientColorAChanged,
    required this.onGradientColorBChanged,
    required this.onGradientDirectionChanged,
    required this.onCardVariantChanged,
    required this.onActionSelectionChanged,
    required this.onCtaRouteChanged,
    required this.onCtaUrlChanged,
    required this.onSortOrderChanged,
    required this.onPriorityChanged,
    required this.onAudienceModeChanged,
    required this.onAudienceChanged,
    required this.onPickStarts,
    required this.onPickEnds,
    required this.onClearSchedule,
    required this.onPickImage,
    required this.onClearImage,
    required this.onDuplicate,
    required this.onArchive,
    required this.onRestoreArchived,
    required this.onSafeDelete,
    required this.onPromoteDemo,
    this.onBeginEdit,
    required this.onPreviewAudience,
  });

  final ProfileFeedItem selected;
  final bool canWrite;
  final bool canPublish;
  final bool editingWorkingDraft;
  final bool busy;
  final bool deleting;
  final bool imageUploading;
  final bool mediaAvailable;
  final TextEditingController titleController;
  final TextEditingController subtitleController;
  final TextEditingController ctaLabelController;
  final TextEditingController ctaRouteController;
  final TextEditingController ctaUrlController;
  final String ctaAction;
  final TextEditingController iconController;
  final TextEditingController gradientAController;
  final TextEditingController gradientBController;
  final int gradientDirection;
  final ContentCardVariant cardVariant;
  final TextEditingController sortOrderController;
  final TextEditingController priorityController;
  final String audienceMode;
  final List<String> groupIds;
  final List<String> userIds;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final ProfileFeedAudiencePreview? audiencePreview;
  final StudentsRepository studentsRepository;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onSubtitleChanged;
  final ValueChanged<String> onCtaLabelChanged;
  final ValueChanged<String?> onIconChanged;
  final ValueChanged<String> onGradientColorAChanged;
  final ValueChanged<String> onGradientColorBChanged;
  final ValueChanged<int> onGradientDirectionChanged;
  final ValueChanged<ContentCardVariant> onCardVariantChanged;
  final ValueChanged<ContentActionSelection> onActionSelectionChanged;
  final ValueChanged<String> onCtaRouteChanged;
  final ValueChanged<String> onCtaUrlChanged;
  final ValueChanged<String> onSortOrderChanged;
  final ValueChanged<String> onPriorityChanged;
  final ValueChanged<String> onAudienceModeChanged;
  final void Function({
    required List<String> groupIds,
    required List<String> userIds,
  })
  onAudienceChanged;
  final VoidCallback onPickStarts;
  final VoidCallback onPickEnds;
  final VoidCallback onClearSchedule;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onDuplicate;
  final VoidCallback onArchive;
  final VoidCallback onRestoreArchived;
  final VoidCallback onSafeDelete;
  final VoidCallback onPromoteDemo;
  final VoidCallback? onBeginEdit;
  final VoidCallback onPreviewAudience;

  bool get _enabled => canWrite && (selected.isDraft || editingWorkingDraft);

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Свойства карточки',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: titleController,
            enabled: _enabled,
            onChanged: onTitleChanged,
            decoration: const InputDecoration(labelText: 'Заголовок'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: subtitleController,
            enabled: _enabled,
            onChanged: onSubtitleChanged,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Подзаголовок'),
          ),
          const SizedBox(height: 12),
          ContentIconPickerField(
            selectedKey: iconController.text.trim().isEmpty
                ? null
                : iconController.text.trim(),
            enabled: _enabled,
            onChanged: onIconChanged,
          ),
          const SizedBox(height: 12),
          ContentGradientField(
            colorA: gradientAController.text,
            colorB: gradientBController.text,
            directionDegrees: gradientDirection,
            enabled: _enabled,
            onColorAChanged: onGradientColorAChanged,
            onColorBChanged: onGradientColorBChanged,
            onDirectionChanged: onGradientDirectionChanged,
          ),
          const SizedBox(height: 12),
          ContentCardVariantPicker(
            selected: cardVariant,
            enabled: _enabled,
            onChanged: onCardVariantChanged,
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 12),
            child: Text(
              'Иконка, градиент и вариант сохраняются в черновик и не меняют '
              'опубликованную карточку, пока вы не опубликуете изменения.',
              style: TextStyle(color: Color(0xFF5C6370), fontSize: 12),
            ),
          ),
          ExpansionTile(
            title: const Text('Диагностика'),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: const [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Шаблон profile_feed_card_v1. '
                  'Публикация расширенного оформления может быть ограничена '
                  'до обновления приложения.',
                  style: TextStyle(color: Color(0xFF5C6370), fontSize: 12),
                ),
              ),
            ],
          ),
          TextField(
            controller: ctaLabelController,
            enabled: _enabled,
            onChanged: onCtaLabelChanged,
            decoration: const InputDecoration(labelText: 'Текст кнопки'),
          ),
          const SizedBox(height: 12),
          ContentActionPicker(
            selection: contentActionFromLegacy(
              ctaAction: ctaAction,
              ctaRoute: ctaRouteController.text,
              ctaUrl: ctaUrlController.text,
            ),
            enabled: _enabled,
            allowedKinds: const [
              ContentActionKind.appScreen,
              ContentActionKind.externalUrl,
              ContentActionKind.none,
            ],
            onChanged: onActionSelectionChanged,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _enabled && !imageUploading ? onPickImage : null,
                  icon: imageUploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_outlined),
                  label: Text(imageUploading ? 'Загрузка…' : 'Иллюстрация'),
                ),
              ),
              if (selected.payload.imageAssetId != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Убрать изображение',
                  onPressed: _enabled ? onClearImage : null,
                  icon: const Icon(Icons.close),
                ),
              ],
            ],
          ),
          if (!mediaAvailable)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Загрузка через content-media доступна только при подключении к Supabase.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ),
          const Divider(height: 28),
          DropdownButtonFormField<String>(
            key: ValueKey('audience-$audienceMode'),
            initialValue: audienceMode,
            isExpanded: true,
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
            onChanged: !_enabled
                ? null
                : (value) {
                    if (value != null) onAudienceModeChanged(value);
                  },
          ),
          const SizedBox(height: 8),
          ContentAudienceSelectors(
            studentsRepository: studentsRepository,
            audienceMode: audienceMode,
            selectedGroupIds: groupIds,
            selectedUserIds: userIds,
            enabled: _enabled,
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
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _enabled ? onPickStarts : null,
                child: Text(
                  startsAt == null
                      ? 'Начало (не задано)'
                      : 'Начало: ${startsAt!.toIso8601String().substring(0, 10)}',
                ),
              ),
              OutlinedButton(
                onPressed: _enabled ? onPickEnds : null,
                child: Text(
                  endsAt == null
                      ? 'Конец (не задано)'
                      : 'Конец: ${endsAt!.toIso8601String().substring(0, 10)}',
                ),
              ),
              if (_enabled)
                TextButton(
                  onPressed: onClearSchedule,
                  child: const Text('Сбросить даты'),
                ),
            ],
          ),
          const Divider(height: 28),
          if (selected.isArchived) ...[
            FilledButton.tonalIcon(
              onPressed: canWrite && !busy && !deleting
                  ? onRestoreArchived
                  : null,
              icon: const Icon(Icons.unarchive_outlined),
              label: const Text('Восстановить как черновик'),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: canPublish && !busy && !deleting ? onSafeDelete : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              icon: deleting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(deleting ? 'Удаление…' : 'Удалить окончательно'),
            ),
          ] else ...[
            if (onBeginEdit != null && !editingWorkingDraft)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: FilledButton.icon(
                  onPressed: busy ? null : onBeginEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Редактировать'),
                ),
              ),
            if (selected.origin == ContentOrigin.demo)
              OutlinedButton.icon(
                onPressed: canWrite && !busy ? onPromoteDemo : null,
                icon: const Icon(Icons.upgrade_outlined),
                label: const Text('Сделать обычной'),
              ),
            if (selected.origin == ContentOrigin.demo)
              const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: canWrite ? onDuplicate : null,
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Дублировать'),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: canWrite ? onArchive : null,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              icon: const Icon(Icons.archive_outlined),
              label: const Text('В архив'),
            ),
          ],
          const SizedBox(height: 16),
          ContentTechnicalPanel(
            children: [
              _ReadOnlyField(label: 'ID', value: selected.id),
              _ReadOnlyField(
                label: 'legacy_key',
                value: selected.legacyKey ?? '—',
              ),
              _ReadOnlyField(
                label: 'row_version',
                value: '${selected.rowVersion}',
              ),
              _ReadOnlyField(
                label: 'version_number',
                value: '${selected.versionNumber}',
              ),
              _ReadOnlyField(label: 'origin', value: selected.origin.labelRu),
              TextField(
                controller: sortOrderController,
                enabled: _enabled,
                keyboardType: TextInputType.number,
                onChanged: onSortOrderChanged,
                decoration: const InputDecoration(labelText: 'sort_order'),
              ),
              TextField(
                controller: priorityController,
                enabled: _enabled,
                keyboardType: TextInputType.number,
                onChanged: onPriorityChanged,
                decoration: const InputDecoration(labelText: 'priority'),
              ),
              TextField(
                controller: ctaRouteController,
                enabled: _enabled,
                onChanged: onCtaRouteChanged,
                decoration: const InputDecoration(labelText: 'cta_route'),
              ),
              TextField(
                controller: ctaUrlController,
                enabled: _enabled,
                onChanged: onCtaUrlChanged,
                decoration: const InputDecoration(labelText: 'cta_url'),
              ),
              _ReadOnlyField(
                label: 'image_asset_id',
                value: selected.payload.imageAssetId ?? '—',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: SelectableText(value),
      ),
    );
  }
}

class _VersionHistoryDialog extends StatelessWidget {
  const _VersionHistoryDialog({required this.versions});

  final List<ProfileFeedVersionInfo> versions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('История версий'),
      content: SizedBox(
        width: 380,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: versions.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final version = versions[index];
            final subtitleParts = <String>[
              if (version.title.isNotEmpty) version.title,
              if (version.status != null) version.status!.russianLabel,
            ];
            return ListTile(
              leading: CircleAvatar(child: Text('${version.versionNumber}')),
              title: Text('Версия ${version.versionNumber}'),
              subtitle: subtitleParts.isEmpty
                  ? null
                  : Text(subtitleParts.join(' · ')),
              trailing: TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(version.versionNumber),
                child: const Text('Восстановить'),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
