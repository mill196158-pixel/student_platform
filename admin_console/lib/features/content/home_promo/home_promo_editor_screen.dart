import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../academic/students/students_repository.dart';
import '../news/admin_image_picker.dart';
import '../news/news_preview.dart';
import '../news/news_repository.dart';
import '../news/supabase_news_repository.dart';
import '../profile_feed/content_audience_selectors.dart';
import '../reference/content_media_store.dart';
import '../shared/admin_content_backend.dart';
import '../shared/content_action_model.dart';
import '../shared/content_action_picker.dart';
import '../shared/content_color_field.dart';
import '../shared/content_card_variant_picker.dart';
import '../shared/content_icon_picker.dart';
import '../shared/content_placement_slot_picker.dart';
import '../shared/content_media_intent.dart';
import '../shared/content_preview_binder.dart';
import '../shared/content_preview_mode.dart';
import '../shared/content_technical_panel.dart';
import '../shared/phone_preview_frame.dart';
import '../shared/visual_editor_list_panel.dart';
import '../shared/visual_editor_operation_error.dart';
import '../shared/visual_editor_publish_coordinator.dart';
import '../shared/visual_editor_shell.dart';
import '../shared/visual_editor_states.dart';
import 'home_promo_item.dart';
import 'home_promo_preview.dart';
import 'home_promo_repository.dart';
import 'supabase_home_promo_repository.dart';

class HomePromoEditorScreen extends StatefulWidget {
  const HomePromoEditorScreen({
    super.key,
    this.repository,
    this.newsRepository,
    this.mediaStore,
    this.imagePicker,
    this.studentsRepository,
    this.session,
  });

  final HomePromoRepository? repository;
  final NewsRepository? newsRepository;
  final ContentMediaStore? mediaStore;
  final AdminImagePicker? imagePicker;
  final StudentsRepository? studentsRepository;
  final AdminSessionController? session;

  @override
  State<HomePromoEditorScreen> createState() => _HomePromoEditorScreenState();
}

class _HomePromoEditorScreenState extends State<HomePromoEditorScreen> {
  late final HomePromoRepository _repository =
      widget.repository ?? _defaultRepo();
  late final NewsRepository _newsRepository =
      widget.newsRepository ?? _defaultNewsRepo();
  late final ContentMediaStore? _mediaStore =
      widget.mediaStore ?? _defaultMedia();
  late final AdminImagePicker _imagePicker =
      widget.imagePicker ?? LocalAdminImagePicker();
  late final StudentsRepository _studentsRepository =
      widget.studentsRepository ?? _defaultStudentsRepo();

  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  final _ctaLabelController = TextEditingController();
  final _ctaRouteController = TextEditingController();
  final _ctaUrlController = TextEditingController();
  final _iconController = TextEditingController(text: 'psychology');
  final _gradientAController = TextEditingController(text: '#FFFBFF');
  final _gradientBController = TextEditingController(text: '#F3EEF9');
  final _reshowController = TextEditingController();

  List<HomePromoItem> _items = [];
  List<StudentHomeNews> _previewNews = const [];
  String? _selectedId;
  VisualEditorListTab _listTab = VisualEditorListTab.published;
  bool _showDemoOnly = false;

  bool _loading = true;
  bool _busy = false;
  bool _publishing = false;
  final _publishCoordinator = VisualEditorPublishCoordinator();
  bool _dirty = false;
  bool _editingWorkingDraft = false;
  bool _dismissible = true;
  bool _isHidden = false;
  String _audienceMode = 'all';
  String _ctaAction = 'route';
  ContentActionSelection _actionSelection = const ContentActionSelection(
    kind: ContentActionKind.none,
  );
  int _gradientDirection = 45;
  ContentHomeSlot _homeSlot = ContentHomeSlot.afterAssignments;
  ContentCardVariant _cardVariant = ContentCardVariant.gradientText;
  ContentPreviewMode _previewMode = ContentPreviewMode.effectiveDraft;
  DateTime? _startsAt;
  DateTime? _endsAt;
  List<String> _groupIds = const [];
  List<String> _userIds = const [];
  HomePromoAudiencePreview? _audiencePreview;

  String? _banner;
  String? _loadError;
  String? _successBanner;
  String? _imageError;
  String? _iconError;
  bool _imageUploading = false;
  bool _iconUploading = false;

  final GlobalKey _selectedPromoAnchorKey = GlobalKey();
  final Map<String, ContentMediaIntentState> _imageIntent = {};
  final Map<String, ContentMediaIntentState> _iconIntent = {};
  final Map<String, Uint8List> _resolvedAssetBytes = {};
  final Map<String, Uint8List> _resolvedIconBytes = {};
  final Set<String> _resolvingAssetIds = {};
  final Set<String> _resolvingIconAssetIds = {};

  _EditorSnapshot? _boundSnapshot;

  HomePromoAdminListPartitions get _partitions =>
      partitionAdminHomePromo(_items);

  List<HomePromoItem> get _tabItems {
    final parts = _partitions;
    final base = switch (_listTab) {
      VisualEditorListTab.published => parts.published,
      VisualEditorListTab.drafts => parts.drafts,
      VisualEditorListTab.archived => parts.archived,
    };
    if (!_showDemoOnly) return base;
    return base.where((item) => item.isDemo).toList();
  }

  HomePromoItem? get _selected {
    if (_selectedId == null) return null;
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

  bool get _canUnpublish => _canPublish;

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  HomePromoRepository _defaultRepo() {
    return AdminContentBackend.resolveRepository<HomePromoRepository>(
      isDemoMode: AdminBackendConfig.isDemoMode,
      client: _tryClient(),
      localFactory: LocalHomePromoRepository.new,
      supabaseFactory: (client) => SupabaseHomePromoRepository(client: client),
    );
  }

  NewsRepository _defaultNewsRepo() {
    return AdminContentBackend.resolveRepository<NewsRepository>(
      isDemoMode: AdminBackendConfig.isDemoMode,
      client: _tryClient(),
      localFactory: LocalNewsRepository.new,
      supabaseFactory: (client) => SupabaseNewsRepository(client: client),
    );
  }

  ContentMediaStore? _defaultMedia() {
    if (AdminBackendConfig.isDemoMode) return null;
    final client = _tryClient();
    if (client == null) return null;
    return ContentMediaStore(client: client);
  }

  StudentsRepository _defaultStudentsRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalStudentsRepository();
    final client = _tryClient();
    if (client != null) return SupabaseStudentsRepository(client: client);
    // Injected content repository (widget tests) without a live client.
    if (widget.repository != null || widget.studentsRepository != null) {
      return LocalStudentsRepository();
    }
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
    _iconController.dispose();
    _gradientAController.dispose();
    _gradientBController.dispose();
    _reshowController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final results = await Future.wait([
        _repository.list(),
        _loadPublishedPreviewNews(),
      ]);
      if (!mounted) return;
      setState(() {
        _items = results[0] as List<HomePromoItem>;
        _loading = false;
        _loadError = null;
        _ensureSelectionForTab();
      });
      _bindSelected();
      _scheduleAssetPreloads();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            e is StateError &&
                e.message == AdminContentBackend.realUnavailableMessage
            ? AdminContentBackend.realUnavailableMessage
            : 'Не удалось загрузить promo-карточки. Попробуйте обновить страницу.';
      });
    }
  }

  Future<void> _loadPublishedPreviewNews() async {
    try {
      final items = await _newsRepository.listNews();
      if (!mounted) return;
      final previewItems = partitionAdminNews(items).publishedPreviewItems;
      setState(() {
        _previewNews = [for (final item in previewItems) item.toPresentation()];
      });
    } catch (_) {
      // Preserve last-good preview news on transient reload failure.
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

  void _bindSelected() {
    final selected = _selected;
    if (selected == null) {
      _boundSnapshot = null;
      setState(() {
        _dirty = false;
        _banner = null;
        _successBanner = null;
      });
      return;
    }
    final p = selected.payload;
    _titleController.text = p.title;
    _subtitleController.text = p.subtitle;
    _ctaLabelController.text = p.ctaLabel;
    _ctaRouteController.text = p.ctaRoute ?? '';
    _ctaUrlController.text = p.ctaUrl ?? '';
    _iconController.text = p.iconKey;
    _gradientAController.text = _hex(p.gradientColors.first);
    _gradientBController.text = _hex(
      p.gradientColors.length > 1
          ? p.gradientColors[1]
          : p.gradientColors.first,
    );
    _reshowController.text = p.reshowAfterHours?.toString() ?? '';
    _dismissible = p.dismissible;
    _isHidden = selected.isHidden;
    _audienceMode = selected.audienceMode;
    _groupIds = [...selected.audienceGroupIds];
    _userIds = [...selected.audienceUserIds];
    _startsAt = selected.startsAt;
    _endsAt = selected.endsAt;
    _ctaAction = (p.ctaUrl != null && p.ctaUrl!.isNotEmpty) ? 'url' : 'route';
    _actionSelection = p.action != null
        ? contentActionFromWire(p.action)
        : contentActionFromLegacy(
            ctaAction: _ctaAction,
            ctaRoute: p.ctaRoute ?? '',
            ctaUrl: p.ctaUrl ?? '',
          );
    if (p.action != null) {
      applyContentActionToLegacy(
        action: _actionSelection,
        onCtaActionChanged: (value) => _ctaAction = value,
        onCtaRouteChanged: (value) => _ctaRouteController.text = value,
        onCtaUrlChanged: (value) => _ctaUrlController.text = value,
      );
    }
    _homeSlot = ContentHomeSlot.fromKey(p.homeSlot);
    _cardVariant =
        ContentCardVariant.fromKey(p.cardVariant) ??
        ContentCardVariant.gradientText;
    _gradientDirection = p.gradientAngle ?? 45;
    if (selected.hasWorkingDraft) {
      _editingWorkingDraft = true;
    }
    _imageIntent.putIfAbsent(
      selected.id,
      () => ContentMediaIntentState(assetId: p.imageAssetId),
    );
    _iconIntent.putIfAbsent(
      selected.id,
      () => ContentMediaIntentState(assetId: p.iconAssetId),
    );
    _boundSnapshot = _captureSnapshot();
    setState(() {
      _dirty = false;
      _banner = null;
      _successBanner = null;
      _imageError = null;
      _iconError = null;
    });
    _scrollSelectedPromoIntoView();
  }

  _EditorSnapshot _captureSnapshot() {
    return _EditorSnapshot(
      title: _titleController.text,
      subtitle: _subtitleController.text,
      ctaLabel: _ctaLabelController.text,
      ctaRoute: _ctaRouteController.text,
      ctaUrl: _ctaUrlController.text,
      iconKey: _iconController.text,
      gradientA: _gradientAController.text,
      gradientB: _gradientBController.text,
      reshow: _reshowController.text,
      dismissible: _dismissible,
      isHidden: _isHidden,
      audienceMode: _audienceMode,
      groupIds: [..._groupIds],
      userIds: [..._userIds],
      startsAt: _startsAt,
      endsAt: _endsAt,
      ctaAction: _ctaAction,
      actionSelection: _actionSelection,
      imageIntent: _intentForSelected(),
      iconIntent: _iconIntentForSelected(),
      homeSlot: _homeSlot,
      cardVariant: _cardVariant,
      gradientDirection: _gradientDirection,
    );
  }

  ContentMediaIntentState _intentForSelected() {
    final id = _selectedId;
    if (id == null) return ContentMediaIntentState.untouched;
    return _imageIntent[id] ?? ContentMediaIntentState.untouched;
  }

  ContentMediaIntentState _iconIntentForSelected() {
    final id = _selectedId;
    if (id == null) return ContentMediaIntentState.untouched;
    return _iconIntent[id] ?? ContentMediaIntentState.untouched;
  }

  void _scrollSelectedPromoIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _selectedPromoAnchorKey.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.2,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    });
  }

  void _markDirty() {
    final nextDirty =
        _boundSnapshot != null && _captureSnapshot() != _boundSnapshot;
    setState(() => _dirty = nextDirty);
  }

  String _hex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  HomePromoPayload? _draftPayload({
    String? imageAssetIdOverride,
    String? iconAssetIdOverride,
  }) {
    final reshowRaw = _reshowController.text.trim();
    final actionSelection = _actionSelection;
    final map = <String, dynamic>{
      'title': _titleController.text.trim(),
      'subtitle': _subtitleController.text.trim(),
      'icon_key': _iconController.text.trim(),
      'gradient_colors': [
        _gradientAController.text.trim(),
        _gradientBController.text.trim(),
      ],
      'cta_label': _ctaLabelController.text.trim(),
      'dismissible': _dismissible,
      'home_slot': _homeSlot.key,
      'card_variant': _cardVariant.key,
      'gradient_angle': _gradientDirection,
      'action': contentActionToWire(actionSelection),
      if (_ctaAction == 'route' && _ctaRouteController.text.trim().isNotEmpty)
        'cta_route': _ctaRouteController.text.trim(),
      if (_ctaAction == 'url' && _ctaUrlController.text.trim().isNotEmpty)
        'cta_url': _ctaUrlController.text.trim(),
      if (reshowRaw.isNotEmpty) 'reshow_after_hours': int.tryParse(reshowRaw),
    };

    final intent = _intentForSelected();
    if (intent.shouldOmitAssetOnSave) {
      // omit image_asset_id
    } else if (imageAssetIdOverride != null &&
        imageAssetIdOverride.isNotEmpty) {
      map['image_asset_id'] = imageAssetIdOverride;
    } else if (intent.assetId != null && intent.assetId!.isNotEmpty) {
      map['image_asset_id'] = intent.assetId;
    } else {
      final existing = _selected?.payload.imageAssetId;
      if (existing != null && existing.isNotEmpty) {
        map['image_asset_id'] = existing;
      }
    }

    final iconIntent = _iconIntentForSelected();
    if (iconIntent.shouldOmitAssetOnSave) {
      // omit icon_asset_id
    } else if (iconAssetIdOverride != null && iconAssetIdOverride.isNotEmpty) {
      map['icon_asset_id'] = iconAssetIdOverride;
    } else if (iconIntent.assetId != null && iconIntent.assetId!.isNotEmpty) {
      map['icon_asset_id'] = iconIntent.assetId;
    } else {
      final existingIcon = _selected?.payload.iconAssetId;
      if (existingIcon != null && existingIcon.isNotEmpty) {
        map['icon_asset_id'] = existingIcon;
      }
    }

    final existingPayload = _selected?.payload;
    if (existingPayload?.overlayOpacity != null) {
      map['overlay_opacity'] = existingPayload!.overlayOpacity;
    }
    if (existingPayload?.focalX != null) {
      map['focal_x'] = existingPayload!.focalX;
    }
    if (existingPayload?.focalY != null) {
      map['focal_y'] = existingPayload!.focalY;
    }
    if (existingPayload?.imageFit != null) {
      map['image_fit'] = existingPayload!.imageFit;
    }

    return HomePromoPayload.tryParse(map);
  }

  void _discardLocalChanges() {
    final snapshot = _boundSnapshot;
    if (snapshot == null) return;
    _titleController.text = snapshot.title;
    _subtitleController.text = snapshot.subtitle;
    _ctaLabelController.text = snapshot.ctaLabel;
    _ctaRouteController.text = snapshot.ctaRoute;
    _ctaUrlController.text = snapshot.ctaUrl;
    _iconController.text = snapshot.iconKey;
    _gradientAController.text = snapshot.gradientA;
    _gradientBController.text = snapshot.gradientB;
    _reshowController.text = snapshot.reshow;
    _dismissible = snapshot.dismissible;
    _isHidden = snapshot.isHidden;
    _audienceMode = snapshot.audienceMode;
    _groupIds = [...snapshot.groupIds];
    _userIds = [...snapshot.userIds];
    _startsAt = snapshot.startsAt;
    _endsAt = snapshot.endsAt;
    _ctaAction = snapshot.ctaAction;
    _actionSelection = snapshot.actionSelection;
    _homeSlot = snapshot.homeSlot;
    _cardVariant = snapshot.cardVariant;
    _gradientDirection = snapshot.gradientDirection;
    final id = _selectedId;
    if (id != null) {
      _imageIntent[id] = snapshot.imageIntent;
      _iconIntent[id] = snapshot.iconIntent;
    }
    setState(() {
      _dirty = false;
      _imageError = null;
      _iconError = null;
    });
  }

  /// True when there is no published-eligible content to show for the phone.
  /// Selecting a draft-only item in published mode must NOT hide other published
  /// promos — only omit the draft overlay.
  bool get _hidePromoPreview {
    if (_selected == null && _partitions.publishedPreviewItems.isEmpty) {
      return true;
    }
    if (_previewMode == ContentPreviewMode.publishedCanonical &&
        _partitions.publishedPreviewItems.isEmpty) {
      return true;
    }
    return false;
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
    } on HomePromoRepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload({String? selectId}) async {
    final items = await _repository.list();
    if (!mounted) return;
    setState(() {
      _items = items;
      if (selectId != null) {
        _selectedId = selectId;
      }
      _ensureSelectionForTab();
    });
    _bindSelected();
    _scheduleAssetPreloads();
  }

  void _select(String id) {
    if (id == _selectedId) return;
    if (_dirty) {
      unawaited(_confirmDiscardDirty(() => _applySelect(id)));
      return;
    }
    _applySelect(id);
  }

  void _applySelect(String id) {
    HomePromoItem? item;
    for (final candidate in _items) {
      if (candidate.id == id) {
        item = candidate;
        break;
      }
    }
    setState(() {
      _selectedId = id;
      if (item?.hasWorkingDraft == true) {
        _editingWorkingDraft = true;
      } else {
        _editingWorkingDraft = false;
      }
    });
    _bindSelected();
    unawaited(_resolveAssetFor(id));
    unawaited(_resolveIconFor(id));
  }

  Future<void> _confirmDiscardDirty(VoidCallback onProceed) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Несохранённые изменения'),
        content: const Text(
          'Переключить карточку без сохранения текущих правок?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Переключить'),
          ),
        ],
      ),
    );
    if (proceed == true && mounted) onProceed();
  }

  void _selectNextAfterRemoval(String removedId, List<HomePromoItem> before) {
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

  Future<List<ContentActionTargetOption>> _loadChatOptions(String query) async {
    if (AdminBackendConfig.isDemoMode) {
      return const [
        ContentActionTargetOption(
          id: '00000000-0000-4000-8000-000000000001',
          label: 'Демо · Общий чат группы',
        ),
      ];
    }
    final client = _tryClient();
    if (client == null) return const [];
    try {
      final data = await client.rpc(
        'admin_list_content_chat_targets',
        params: {'p_query': query.trim().isEmpty ? null : query.trim()},
      );
      dynamic value = data;
      if (value is String && value.isNotEmpty) {
        value = jsonDecode(value);
      }
      if (value is! List) return const [];
      return [
        for (final row in value.whereType<Map>())
          ContentActionTargetOption(
            id: (row['chat_id'] ?? '').toString(),
            label: [
              (row['title'] ?? 'Чат').toString(),
              if ((row['chat_kind_label'] ?? '').toString().isNotEmpty)
                (row['chat_kind_label'] ?? '').toString(),
            ].join(' · '),
          ),
      ].where((e) => e.id.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _beginEdit() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _run(() async {
      final item = await _repository.beginEdit(selected.id);
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((e) => e.id == item.id);
        if (idx >= 0) _items = [..._items]..[idx] = item;
        _editingWorkingDraft = true;
      });
      _bindSelected();
    });
  }

  Future<void> _discardWorkingDraft() async {
    final selected = _selected;
    if (selected == null || !_canWrite) return;
    await _run(() async {
      final item = await _repository.discardWorkingDraft(selected.id);
      if (!mounted) return;
      setState(() {
        _editingWorkingDraft = false;
        final idx = _items.indexWhere((e) => e.id == item.id);
        if (idx >= 0) _items = [..._items]..[idx] = item;
      });
      _bindSelected();
      setState(() => _successBanner = 'Изменения отменены.');
    });
  }

  Future<void> _create() async {
    await _run(() async {
      final payload = HomePromoPayload.tryParse({
        'title': 'Новая promo-карточка',
        'subtitle': 'Краткое описание',
        'icon_key': 'psychology',
        'gradient_colors': ['#FFFBFF', '#F3EEF9'],
        'cta_label': 'Подробнее',
        'dismissible': true,
        'cta_route': '/help',
        'home_slot': ContentHomeSlot.afterAssignments.key,
        'card_variant': ContentCardVariant.gradientText.key,
        'gradient_angle': 45,
        'action': contentActionToWire(
          const ContentActionSelection(
            kind: ContentActionKind.appScreen,
            screenKey: 'info',
          ),
        ),
      });
      if (payload == null) {
        setState(() => _banner = 'Не удалось создать черновик.');
        return;
      }
      final created = await _repository.createDraft(payload: payload);
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: created.id);
      setState(() => _successBanner = 'Черновик создан.');
    });
  }

  Future<HomePromoItem?> _saveSelected() async {
    final selected = _selected;
    if (selected == null) return null;
    final payload = _draftPayload();
    if (payload == null) {
      setState(() => _banner = 'Проверьте поля карточки (fail-closed parse).');
      return null;
    }

    var next = selected.copyWith(
      title: payload.title,
      payload: payload,
      isHidden: _isHidden,
      startsAt: _startsAt,
      endsAt: _endsAt,
      clearStartsAt: _startsAt == null,
      clearEndsAt: _endsAt == null,
    );

    final intent = _intentForSelected();
    final iconIntent = _iconIntentForSelected();
    final media = _mediaStore;
    String? uploadedImageAssetId;
    String? uploadedIconAssetId;

    if (intent.hasLocalPick && media != null) {
      setState(() => _imageUploading = true);
      final bytes = intent.localBytes;
      if (bytes == null) {
        setState(() {
          _imageUploading = false;
          _banner = 'Локальное изображение не найдено.';
        });
        return null;
      }
      try {
        final uploaded = await media.uploadBytesDetailed(
          contentItemId: selected.id,
          bytes: bytes,
          contentType: 'image/png',
          title: payload.title,
        );
        uploadedImageAssetId = uploaded.assetId;
        if (uploaded.workingDraftRowVersion != null) {
          next = next.copyWith(
            workingDraftRowVersion: uploaded.workingDraftRowVersion,
          );
        }
        // Keep local bytes visible until authorized download resolves.
        setState(() {
          _resolvedAssetBytes[selected.id] = bytes;
          _imageIntent[selected.id] = ContentMediaIntentState(
            assetId: uploaded.assetId,
          ).pickLocal(bytes);
        });
      } catch (error) {
        if (mounted) {
          setState(() {
            _imageUploading = false;
            _banner = _mediaUploadBanner('изображение', error);
          });
        }
        return null;
      } finally {
        if (mounted) setState(() => _imageUploading = false);
      }
    }

    if (iconIntent.hasLocalPick && media != null) {
      setState(() => _iconUploading = true);
      final bytes = iconIntent.localBytes;
      if (bytes == null) {
        setState(() {
          _iconUploading = false;
          _banner = 'Локальная иконка не найдена.';
        });
        return null;
      }
      try {
        final uploaded = await media.uploadBytesDetailed(
          contentItemId: selected.id,
          bytes: bytes,
          contentType: 'image/png',
          title: '${payload.title} icon',
        );
        uploadedIconAssetId = uploaded.assetId;
        if (uploaded.workingDraftRowVersion != null) {
          next = next.copyWith(
            workingDraftRowVersion: uploaded.workingDraftRowVersion,
          );
        }
        setState(() {
          _resolvedIconBytes[selected.id] = bytes;
          _iconIntent[selected.id] = ContentMediaIntentState(
            assetId: uploaded.assetId,
          ).pickLocal(bytes);
        });
      } catch (error) {
        if (mounted) {
          setState(() {
            _iconUploading = false;
            _banner = _mediaUploadBanner('иконку', error);
          });
        }
        return null;
      } finally {
        if (mounted) setState(() => _iconUploading = false);
      }
    }

    final savedPayload = _draftPayload(
      imageAssetIdOverride: intent.shouldOmitAssetOnSave
          ? ''
          : uploadedImageAssetId,
      iconAssetIdOverride: iconIntent.shouldOmitAssetOnSave
          ? ''
          : uploadedIconAssetId,
    );
    if (savedPayload == null) return null;
    next = next.copyWith(payload: savedPayload);

    if (_editingWorkingDraft) {
      final draftVersion = next.workingDraftRowVersion;
      if (draftVersion == null) {
        setState(() => _banner = 'Черновик изменений не найден.');
        return null;
      }
      next = await _repository.saveWorkingDraft(
        next,
        expectedDraftRowVersion: draftVersion,
      );
      if (!mounted) return next;
      setState(() {
        final idx = _items.indexWhere((e) => e.id == next.id);
        if (idx >= 0) _items = [..._items]..[idx] = next;
        _selectedId = next.id;
        _imageIntent[next.id] = ContentMediaIntentState(
          assetId: next.payload.imageAssetId,
        );
        _iconIntent[next.id] = ContentMediaIntentState(
          assetId: next.payload.iconAssetId,
        );
        _dirty = false;
        _boundSnapshot = _captureSnapshot();
      });
      unawaited(_resolveAssetFor(next.id));
      unawaited(_resolveIconFor(next.id));
      return next;
    }

    next = await _repository.updateDraft(next);
    next = await _repository.setAudience(
      id: next.id,
      audienceMode: _audienceMode,
      groupIds: _groupIds,
      userIds: _userIds,
      expectedRowVersion: next.rowVersion,
    );

    if (!mounted) return next;
    setState(() {
      final idx = _items.indexWhere((e) => e.id == next.id);
      if (idx >= 0) _items = [..._items]..[idx] = next;
      _selectedId = next.id;
      _imageIntent[next.id] = ContentMediaIntentState(
        assetId: next.payload.imageAssetId,
      );
      _iconIntent[next.id] = ContentMediaIntentState(
        assetId: next.payload.iconAssetId,
      );
      _dirty = false;
      _boundSnapshot = _captureSnapshot();
    });
    unawaited(_resolveAssetFor(next.id));
    unawaited(_resolveIconFor(next.id));
    return next;
  }

  Future<void> _saveDraft() async {
    if (!_canWrite) {
      setState(() => _banner = 'Недостаточно прав для сохранения.');
      return;
    }
    await _run(() async {
      final saved = await _saveSelected();
      if (saved != null) {
        setState(() => _successBanner = 'Черновик сохранён.');
      }
    });
  }

  Future<void> _publish() async {
    final selected = _selected;
    if (selected == null || _busy || _publishing) return;
    setState(() {
      _publishing = true;
      _busy = true;
      _banner = null;
      _successBanner = null;
    });
    try {
      final published = await _publishCoordinator.publishChanges<HomePromoItem>(
        editingWorkingDraft: _editingWorkingDraft,
        validate: () async {
          if (_draftPayload() == null) {
            return 'Проверьте поля карточки (fail-closed parse).';
          }
          return null;
        },
        uploadPendingMedia: () async {
          // Uploads are performed inside autosave so asset ids land in the patch.
          return null;
        },
        saveDraft: () async {
          // Always autosave before publish (WD row_version may have moved via media).
          final saved = await _saveSelected();
          if (saved == null) {
            throw VisualEditorOperationError(
              _banner ?? 'Не удалось сохранить черновик перед публикацией.',
              code: 'autosave_failed',
            );
          }
          if (_editingWorkingDraft) {
            final draftRv = saved.workingDraftRowVersion;
            if (draftRv == null) {
              throw const VisualEditorOperationError(
                'Сначала создайте черновик изменений',
                code: 'working_draft_required',
              );
            }
            return VisualEditorSavedDraft(
              item: saved,
              expectedDraftRowVersion: draftRv,
            );
          }
          return VisualEditorSavedDraft(
            item: saved,
            expectedDraftRowVersion: saved.rowVersion,
          );
        },
        publishWorkingDraft: ({required expectedDraftRowVersion}) {
          return _repository.publishWorkingDraft(
            selected.id,
            expectedDraftRowVersion: expectedDraftRowVersion,
          );
        },
        publishCanonical: () {
          final current = _selected ?? selected;
          return _repository.publish(current.id, current.rowVersion);
        },
        refetch: (item) async {
          await _reload(selectId: item.id);
          return _selected ?? item;
        },
      );
      if (!mounted) return;
      final wasWorkingDraft = _editingWorkingDraft;
      setState(() {
        _editingWorkingDraft = false;
        _listTab = VisualEditorListTab.published;
        _selectedId = published.id;
        _successBanner = wasWorkingDraft
            ? 'Изменения опубликованы.'
            : 'Опубликовано.';
      });
    } on VisualEditorOperationError catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.message);
    } on HomePromoRepositoryException catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _banner = mapVisualEditorOperationError(
          error,
          stage: 'publish',
        ).message,
      );
    } finally {
      if (mounted) {
        setState(() {
          _publishing = false;
          _busy = false;
        });
      }
    }
  }

  Future<void> _unpublish() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final updated = await _repository.unpublish(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: updated.id);
      setState(() => _successBanner = 'Снято с публикации.');
    });
  }

  Future<void> _archive() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final archived = await _repository.archive(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.archived);
      await _reload(selectId: archived.id);
      setState(() => _successBanner = 'Перемещено в архив.');
    });
  }

  Future<void> _restoreArchived() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final restored = await _repository.restoreArchived(
        selected.id,
        selected.rowVersion,
      );
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: restored.id);
      setState(() => _successBanner = 'Восстановлено из архива.');
    });
  }

  Future<void> _safeDelete() async {
    final selected = _selected;
    if (selected == null || !selected.isArchived) return;
    final confirmController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить навсегда?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Введите заголовок карточки для подтверждения: «${selected.title}»',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmController,
              decoration: const InputDecoration(
                labelText: 'Заголовок карточки',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(confirmController.text.trim() == selected.title.trim()),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    confirmController.dispose();
    if (confirmed != true) return;
    final before = List<HomePromoItem>.from(_tabItems);
    final removedId = selected.id;
    await _run(() async {
      await _repository.safeDelete(selected.id, selected.rowVersion);
      if (!mounted) return;
      await _reload();
      setState(() {
        _selectNextAfterRemoval(removedId, before);
        _editingWorkingDraft = false;
      });
      _bindSelected();
      setState(() => _successBanner = 'Карточка удалена.');
    });
  }

  Future<void> _duplicate() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      final copy = await _repository.duplicate(selected.id);
      if (!mounted) return;
      setState(() => _listTab = VisualEditorListTab.drafts);
      await _reload(selectId: copy.id);
      setState(() => _successBanner = 'Копия создана.');
    });
  }

  Future<void> _promoteDemo() async {
    final selected = _selected;
    if (selected == null || !selected.isDemo) return;
    await _run(() async {
      final promoted = await _repository.promoteDemo(
        selected.id,
        selected.rowVersion,
      );
      await _reload(selectId: promoted.id);
      setState(
        () => _successBanner = 'Демо-карточка переведена в управляемую.',
      );
    });
  }

  Future<void> _showVersions() async {
    final selected = _selected;
    if (selected == null) return;
    List<HomePromoVersionInfo>? versions;
    await _run(() async {
      versions = await _repository.listVersions(selected.id);
    });
    if (versions == null || !mounted) return;
    if (versions!.isEmpty) {
      setState(() => _successBanner = 'История версий пуста.');
      return;
    }
    final restore = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _VersionHistoryDialog(versions: versions!),
    );
    if (restore == null) return;
    await _run(() async {
      final restored = await _repository.restoreVersion(selected.id, restore);
      await _reload(selectId: restored.id);
      setState(() => _successBanner = 'Версия $restore восстановлена.');
    });
  }

  Future<void> _move(int delta) async {
    final tabItems = _tabItems;
    final index = tabItems.indexWhere((e) => e.id == _selectedId);
    if (index < 0) return;
    final target = index + delta;
    if (target < 0 || target >= tabItems.length) return;
    final reordered = [...tabItems];
    final item = reordered.removeAt(index);
    reordered.insert(target, item);
    await _run(() async {
      await _repository.reorder(
        reordered.map((e) => e.id).toList(),
        reordered.map((e) => e.rowVersion).toList(),
      );
      await _reload(selectId: item.id);
      setState(() => _successBanner = 'Порядок обновлён.');
    });
  }

  String _mediaUploadBanner(String label, Object error) {
    final text = error.toString();
    if (text.contains('working_draft_required') ||
        text.contains('draft_only')) {
      return 'Сначала откройте «Редактировать», затем сохраните изображение.';
    }
    if (text.contains('archived_immutable')) {
      return 'Архивная карточка неизменяема.';
    }
    if (text.contains('forbidden') || text.contains('403')) {
      return 'Недостаточно прав для загрузки $label.';
    }
    return 'Не удалось загрузить $label: $error';
  }

  Future<void> _pickImage() async {
    final selected = _selected;
    if (selected == null || !_canWrite || selected.isArchived) return;
    try {
      final picked = await _imagePicker.pickImage();
      if (picked == null) return;
      setState(() {
        _imageIntent[selected.id] =
            (_imageIntent[selected.id] ?? ContentMediaIntentState.untouched)
                .pickLocal(picked.bytes);
        _imageError = null;
      });
      _markDirty();
    } on AdminImagePickException catch (error) {
      setState(() => _imageError = error.message);
    }
  }

  void _clearImage() {
    final selected = _selected;
    if (selected == null || !_canWrite || selected.isArchived) return;
    setState(() {
      _resolvedAssetBytes.remove(selected.id);
      _imageIntent[selected.id] = _intentFor(selected.id).markRemoved();
      _imageError = null;
    });
    _markDirty();
  }

  Future<void> _pickIcon() async {
    final selected = _selected;
    if (selected == null || !_canWrite || selected.isArchived) return;
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'webp'],
        withData: true,
        allowMultiple: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final file = picked.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const AdminImagePickException(
          'Не удалось прочитать файл. Выберите изображение ещё раз.',
        );
      }
      if (bytes.length > LocalAdminImagePicker.maxBytes) {
        throw const AdminImagePickException(
          'Изображение слишком большое. Максимум 5 МБ.',
        );
      }
      final ext = (file.extension ?? '').toLowerCase();
      if (ext != 'png' && ext != 'webp') {
        throw const AdminImagePickException(
          'Для своей иконки поддерживаются только PNG и WebP.',
        );
      }
      setState(() {
        _iconIntent[selected.id] =
            (_iconIntent[selected.id] ?? ContentMediaIntentState.untouched)
                .pickLocal(bytes);
        _iconError = null;
      });
      _markDirty();
    } on AdminImagePickException catch (error) {
      setState(() => _iconError = error.message);
    }
  }

  void _clearIcon() {
    final selected = _selected;
    if (selected == null || !_canWrite || selected.isArchived) return;
    setState(() {
      _resolvedIconBytes.remove(selected.id);
      _iconIntent[selected.id] = _iconIntentFor(selected.id).markRemoved();
      _iconError = null;
    });
    _markDirty();
  }

  void _scheduleAssetPreloads() {
    final media = _mediaStore;
    if (media == null) return;
    for (final item in _items.take(8)) {
      unawaited(_resolveAssetFor(item.id));
      unawaited(_resolveIconFor(item.id));
    }
    final selected = _selected;
    if (selected != null) {
      unawaited(_resolveAssetFor(selected.id));
      unawaited(_resolveIconFor(selected.id));
    }
  }

  Future<void> _resolveAssetFor(String itemId) async {
    final media = _mediaStore;
    if (media == null) return;
    final intent = _intentFor(itemId);
    if (intent.hasLocalPick) return;
    if (intent.shouldOmitAssetOnSave) return;
    if (_resolvingAssetIds.contains(itemId)) return;

    HomePromoItem? item;
    for (final candidate in _items) {
      if (candidate.id == itemId) {
        item = candidate;
        break;
      }
    }
    final assetId = item?.payload.imageAssetId;
    if (assetId == null || assetId.isEmpty) return;

    // Generation token: ignore stale completions after switch/remove/replace.
    final generation = Object.hash(itemId, assetId, intent.phase);
    _resolvingAssetIds.add(itemId);
    try {
      final bytes = await media.downloadBytes(assetId: assetId);
      if (!mounted || bytes == null) return;
      final latest = _intentFor(itemId);
      if (latest.hasLocalPick || latest.shouldOmitAssetOnSave) return;
      HomePromoItem? latestItem;
      for (final candidate in _items) {
        if (candidate.id == itemId) {
          latestItem = candidate;
          break;
        }
      }
      final latestAssetId = latestItem?.payload.imageAssetId;
      if (latestAssetId != assetId) return;
      final latestGeneration = Object.hash(itemId, latestAssetId, latest.phase);
      if (latestGeneration != generation) return;
      setState(() => _resolvedAssetBytes[itemId] = bytes);
    } catch (_) {
      // Preview falls back to skeleton.
    } finally {
      _resolvingAssetIds.remove(itemId);
    }
  }

  ContentMediaIntentState _intentFor(String itemId) =>
      _imageIntent[itemId] ?? ContentMediaIntentState.untouched;

  ContentMediaIntentState _iconIntentFor(String itemId) =>
      _iconIntent[itemId] ?? ContentMediaIntentState.untouched;

  Future<void> _resolveIconFor(String itemId) async {
    final media = _mediaStore;
    if (media == null) return;
    final intent = _iconIntentFor(itemId);
    if (intent.hasLocalPick) return;
    if (intent.shouldOmitAssetOnSave) return;
    if (_resolvingIconAssetIds.contains(itemId)) return;

    HomePromoItem? item;
    for (final candidate in _items) {
      if (candidate.id == itemId) {
        item = candidate;
        break;
      }
    }
    final assetId = item?.payload.iconAssetId;
    if (assetId == null || assetId.isEmpty) return;

    final generation = Object.hash(itemId, assetId, intent.phase);
    _resolvingIconAssetIds.add(itemId);
    try {
      final bytes = await media.downloadBytes(assetId: assetId);
      if (!mounted || bytes == null) return;
      final latest = _iconIntentFor(itemId);
      if (latest.hasLocalPick || latest.shouldOmitAssetOnSave) return;
      HomePromoItem? latestItem;
      for (final candidate in _items) {
        if (candidate.id == itemId) {
          latestItem = candidate;
          break;
        }
      }
      final latestAssetId = latestItem?.payload.iconAssetId;
      if (latestAssetId != assetId) return;
      final latestGeneration = Object.hash(itemId, latestAssetId, latest.phase);
      if (latestGeneration != generation) return;
      setState(() => _resolvedIconBytes[itemId] = bytes);
    } catch (_) {
      // Preview falls back to built-in icon key.
    } finally {
      _resolvingIconAssetIds.remove(itemId);
    }
  }

  Uint8List? _previewImageBytes() {
    final selected = _selected;
    if (selected == null) return null;
    final intent = _intentFor(selected.id);
    final local = intent.bytesForPreview;
    if (local != null) return local;
    if (intent.shouldOmitAssetOnSave) return null;
    return _resolvedAssetBytes[selected.id];
  }

  Uint8List? _previewIconBytes() {
    final selected = _selected;
    if (selected == null) return null;
    final intent = _iconIntentFor(selected.id);
    final local = intent.bytesForPreview;
    if (local != null) return local;
    if (intent.shouldOmitAssetOnSave) return null;
    return _resolvedIconBytes[selected.id];
  }

  bool _assetLoading() {
    final selected = _selected;
    if (selected == null) return false;
    final intent = _intentFor(selected.id);
    if (intent.hasLocalPick) return false;
    if (intent.shouldOmitAssetOnSave) return false;
    final assetId = selected.payload.imageAssetId;
    if (assetId == null || assetId.isEmpty) return false;
    return !_resolvedAssetBytes.containsKey(selected.id) &&
        _resolvingAssetIds.contains(selected.id);
  }

  bool _iconAssetLoading() {
    final selected = _selected;
    if (selected == null) return false;
    final intent = _iconIntentFor(selected.id);
    if (intent.hasLocalPick) return false;
    if (intent.shouldOmitAssetOnSave) return false;
    final assetId = selected.payload.iconAssetId;
    if (assetId == null || assetId.isEmpty) return false;
    return !_resolvedIconBytes.containsKey(selected.id) &&
        _resolvingIconAssetIds.contains(selected.id);
  }

  ContentImageRenderState _imageStateForPreview({
    required HomePromoPayload payload,
    Uint8List? imageBytes,
    bool imageLoading = false,
  }) {
    return ContentImageRenderState.fromLegacy(
      usesImageVariant: contentCardVariantUsesImage(
        effectiveContentCardVariant(payload.cardVariant),
      ),
      bytes: imageBytes,
      loading: imageLoading,
    );
  }

  Uint8List? _imageBytesForItem(String itemId, HomePromoPayload payload) {
    if (itemId == _selectedId) return _previewImageBytes();
    final intent = _intentFor(itemId);
    if (intent.shouldOmitAssetOnSave) return null;
    final local = intent.bytesForPreview;
    if (local != null) return local;
    return _resolvedAssetBytes[itemId];
  }

  Uint8List? _iconBytesForItem(String itemId, HomePromoPayload payload) {
    if (itemId == _selectedId) return _previewIconBytes();
    final intent = _iconIntentFor(itemId);
    if (intent.shouldOmitAssetOnSave) return null;
    final local = intent.bytesForPreview;
    if (local != null) return local;
    return _resolvedIconBytes[itemId];
  }

  bool _shouldOverlaySelectedInPreview(HomePromoItem selected) {
    if (_previewMode == ContentPreviewMode.publishedCanonical) {
      return false;
    }
    return shouldOverlayLiveDraft(
      isDraft: selected.isDraft && !selected.isPublished,
      editingWorkingDraft: _editingWorkingDraft,
      dirty: _dirty,
      mode: _previewMode,
    );
  }

  HomePromoItem? _itemById(String id) {
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  List<StudentHomePromoPlacement> _buildPreviewPlacements() {
    final selected = _selected;
    final selectedId = _selectedId;
    final byId = <String, StudentHomePromoPlacement>{};
    final publishedMode = _previewMode == ContentPreviewMode.publishedCanonical;

    for (final item in _partitions.publishedPreviewItems) {
      final isSelected = item.id == selectedId;
      byId[item.id] = StudentHomePromoPlacement(
        payload: item.payload,
        slot: item.payload.effectiveHomeSlot,
        showDemoBadge: item.isDemo,
        imageBytes: _imageBytesForItem(item.id, item.payload),
        iconBytes: _iconBytesForItem(item.id, item.payload),
        imageLoading: isSelected && _assetLoading(),
        imageState: _imageStateForPreview(
          payload: item.payload,
          imageBytes: _imageBytesForItem(item.id, item.payload),
          imageLoading: isSelected && _assetLoading(),
        ),
        anchorKey: isSelected ? _selectedPromoAnchorKey : null,
      );
    }

    // Draft overlay / draft-only inclusion only in live-draft preview mode.
    if (!publishedMode) {
      if (selected != null && _shouldOverlaySelectedInPreview(selected)) {
        final payload = _draftPayload() ?? selected.payload;
        byId[selected.id] = StudentHomePromoPlacement(
          payload: payload,
          slot: _homeSlot.key,
          showDemoBadge: selected.isDemo,
          imageBytes: _previewImageBytes(),
          iconBytes: _previewIconBytes(),
          imageLoading: _assetLoading(),
          imageState: _imageStateForPreview(
            payload: payload,
            imageBytes: _previewImageBytes(),
            imageLoading: _assetLoading(),
          ),
          anchorKey: _selectedPromoAnchorKey,
        );
      } else if (selected != null &&
          selectedId != null &&
          !byId.containsKey(selectedId)) {
        final payload = (_dirty ? _draftPayload() : null) ?? selected.payload;
        byId[selectedId] = StudentHomePromoPlacement(
          payload: payload,
          slot: _dirty || _editingWorkingDraft
              ? _homeSlot.key
              : payload.effectiveHomeSlot,
          showDemoBadge: selected.isDemo,
          imageBytes: _previewImageBytes(),
          iconBytes: _previewIconBytes(),
          imageLoading: _assetLoading(),
          imageState: _imageStateForPreview(
            payload: payload,
            imageBytes: _previewImageBytes(),
            imageLoading: _assetLoading(),
          ),
          anchorKey: _selectedPromoAnchorKey,
        );
      } else if (selected != null &&
          selectedId != null &&
          byId.containsKey(selectedId)) {
        final existing = byId[selectedId]!;
        byId[selectedId] = StudentHomePromoPlacement(
          payload: existing.payload,
          slot: existing.slot,
          showDemoBadge: existing.showDemoBadge,
          imageBytes: existing.imageBytes,
          iconBytes: existing.iconBytes,
          imageLoading: existing.imageLoading,
          imageState: existing.imageState,
          anchorKey: _selectedPromoAnchorKey,
        );
      }
    } else if (selected != null &&
        selectedId != null &&
        byId.containsKey(selectedId)) {
      // Published mode: keep published payload, only attach scroll anchor.
      final existing = byId[selectedId]!;
      byId[selectedId] = StudentHomePromoPlacement(
        payload: existing.payload,
        slot: existing.slot,
        showDemoBadge: existing.showDemoBadge,
        imageBytes: existing.imageBytes,
        iconBytes: existing.iconBytes,
        imageLoading: existing.imageLoading,
        imageState: existing.imageState,
        anchorKey: _selectedPromoAnchorKey,
      );
    }

    final sortedIds = byId.keys.toList()
      ..sort((a, b) {
        final itemA = _itemById(a);
        final itemB = _itemById(b);
        final byOrder = (itemA?.sortOrder ?? 0).compareTo(
          itemB?.sortOrder ?? 0,
        );
        if (byOrder != 0) return byOrder;
        final byPriority = (itemB?.priority ?? 0).compareTo(
          itemA?.priority ?? 0,
        );
        if (byPriority != 0) return byPriority;
        return a.compareTo(b);
      });
    return [for (final id in sortedIds) byId[id]!];
  }

  Future<void> _pickDate({required bool starts}) async {
    final initial = (starts ? _startsAt : _endsAt) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024),
      lastDate: DateTime(2035),
      helpText: starts ? 'Дата начала показа' : 'Дата окончания показа',
    );
    if (date == null) return;
    setState(() {
      if (starts) {
        _startsAt = date;
      } else {
        _endsAt = date;
      }
    });
    _markDirty();
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

  VisualEditorTabCounts get _tabCounts {
    final parts = _partitions;
    return VisualEditorTabCounts(
      published: parts.published.length,
      drafts: parts.drafts.length,
      archived: parts.archived.length,
    );
  }

  String? get _headerBanner {
    if (_banner != null) return _banner;
    if (_successBanner != null) return null;
    return null;
  }

  String? get _infoBanner {
    if (_banner != null) return null;
    return _successBanner;
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
    final previewPlacements = _buildPreviewPlacements();
    final parts = _partitions;
    final v2PublishBlocked =
        _draftPayload() != null &&
        contentWireUsesV2PublishFeatures(_draftPayload()!.toWireJson());

    return Padding(
      padding: const EdgeInsets.all(20),
      child: VisualEditorShell(
        title: 'Главная · promo',
        selectedTitle: selected?.title,
        statusChip: selected?.status.russianLabel,
        originDemoBadge: selected?.isDemo ?? false,
        dirty: _dirty,
        busy: _busy || _imageUploading || _iconUploading,
        publishing: _publishing,
        banner: _headerBanner,
        defaultInfoMessage:
            _infoBanner ??
            (v2PublishBlocked
                ? kVisualStudioV2PublishBlockedMessageRu
                : 'Изменения сохраняются на сервере. Публикация видна студентам сразу.'),
        canWrite: _canWrite,
        canPublish: _canPublish && selected != null && !selected.isArchived,
        canUnpublish: _canUnpublish,
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
        onSaveDraft:
            _canWrite && (selected?.isDraft == true || _editingWorkingDraft)
            ? _saveDraft
            : null,
        onPublish: _canPublish ? _publish : null,
        onUnpublish: _canUnpublish ? _unpublish : null,
        onVersions: _showVersions,
        onPopDirtyConfirm: _handlePopDirtyConfirm,
        editingWorkingDraft: _editingWorkingDraft,
        onDiscardWorkingDraft: _editingWorkingDraft && _canWrite
            ? _discardWorkingDraft
            : null,
        onDiscardLocalChanges: _dirty && _canWrite
            ? _discardLocalChanges
            : null,
        listBuilder: (_) => VisualEditorListPanel(
          panelTitle: 'Promo-карточки',
          tab: _listTab,
          tabCounts: _tabCounts,
          items: [
            for (final item in _tabItems)
              VisualEditorListItem(
                id: item.id,
                title: item.title,
                subtitle: item.payload.subtitle,
                isDemo: item.isDemo,
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
          onMove: _canWrite && _listTab != VisualEditorListTab.archived
              ? _move
              : null,
          onCreate: _canWrite ? _create : null,
          showDemoOnly: _showDemoOnly,
          onDemoFilterChanged: (value) => setState(() => _showDemoOnly = value),
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
              child: PhonePreviewFrame(
                child: Theme(
                  data: studentPlatformLightTheme(),
                  child: _hidePromoPreview && previewPlacements.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Нет опубликованной версии для предпросмотра',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : _HomePromoPhonePreview(
                          placements: previewPlacements,
                          news: _previewNews,
                          selectedId: _selectedId,
                          onPlacementsBuilt: _scrollSelectedPromoIntoView,
                        ),
                ),
              ),
            ),
          ],
        ),
        propertiesBuilder: (_) => selected == null
            ? VisualEditorEmptyState(
                message: _tabItems.isEmpty
                    ? _listTab.emptyMessageRu
                    : 'Выберите promo-карточку',
                actionLabel: _canWrite && _tabItems.isEmpty ? 'Создать' : null,
                onAction: _canWrite && _tabItems.isEmpty ? _create : null,
              )
            : _PropertiesPanel(
                selected: selected,
                canWrite: _canWrite,
                canPublish: _canPublish,
                editingWorkingDraft: _editingWorkingDraft,
                busy: _busy,
                titleController: _titleController,
                subtitleController: _subtitleController,
                iconController: _iconController,
                gradientAController: _gradientAController,
                gradientBController: _gradientBController,
                ctaLabelController: _ctaLabelController,
                ctaRouteController: _ctaRouteController,
                ctaUrlController: _ctaUrlController,
                reshowController: _reshowController,
                dismissible: _dismissible,
                isHidden: _isHidden,
                audienceMode: _audienceMode,
                groupIds: _groupIds,
                userIds: _userIds,
                audiencePreview: _audiencePreview,
                ctaAction: _ctaAction,
                actionSelection: _actionSelection,
                loadChatOptions: _loadChatOptions,
                gradientDirection: _gradientDirection,
                homeSlot: _homeSlot,
                cardVariant: _cardVariant,
                onHomeSlotChanged: (value) {
                  setState(() => _homeSlot = value);
                  _markDirty();
                  _scrollSelectedPromoIntoView();
                },
                onCardVariantChanged: (value) {
                  setState(() => _cardVariant = value);
                  _markDirty();
                },
                onGradientDirectionChanged: (value) {
                  setState(() => _gradientDirection = value);
                  _markDirty();
                },
                onActionSelectionChanged: (action) {
                  _actionSelection = action;
                  applyContentActionToLegacy(
                    action: action,
                    onCtaActionChanged: (value) => _ctaAction = value,
                    onCtaRouteChanged: (value) =>
                        _ctaRouteController.text = value,
                    onCtaUrlChanged: (value) => _ctaUrlController.text = value,
                  );
                  _markDirty();
                },
                startsAt: _startsAt,
                endsAt: _endsAt,
                imageBytes: _previewImageBytes(),
                imageLoading: _assetLoading(),
                imageError: _imageError,
                iconBytes: _previewIconBytes(),
                iconLoading: _iconAssetLoading(),
                iconError: _iconError,
                studentsRepository: _studentsRepository,
                onChanged: _markDirty,
                onDismissibleChanged: (value) {
                  setState(() => _dismissible = value);
                  _markDirty();
                },
                onHiddenChanged: (value) {
                  setState(() => _isHidden = value);
                  _markDirty();
                },
                onAudienceModeChanged: (value) {
                  setState(() => _audienceMode = value);
                  _markDirty();
                },
                onAudienceSelectionChanged:
                    ({required groupIds, required userIds}) {
                      setState(() {
                        _groupIds = groupIds;
                        _userIds = userIds;
                      });
                      _markDirty();
                    },
                onPickImage: _pickImage,
                onClearImage: _clearImage,
                onPickIcon: _pickIcon,
                onClearIcon: _clearIcon,
                onPreviewAudience: _previewAudience,
                onPickDate: _pickDate,
                onClearStarts: () {
                  setState(() => _startsAt = null);
                  _markDirty();
                },
                onClearEnds: () {
                  setState(() => _endsAt = null);
                  _markDirty();
                },
                onDuplicate: _duplicate,
                onArchive: selected.isArchived ? null : _archive,
                onRestoreArchived: selected.isArchived
                    ? _restoreArchived
                    : null,
                onSafeDelete: selected.isArchived ? _safeDelete : null,
                onPromoteDemo: selected.isDemo ? _promoteDemo : null,
                onBeginEdit: !selected.isDraft && !selected.isArchived
                    ? _beginEdit
                    : null,
                publishedCount: parts.published.length,
              ),
      ),
    );
  }
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.title,
    required this.subtitle,
    required this.ctaLabel,
    required this.ctaRoute,
    required this.ctaUrl,
    required this.iconKey,
    required this.gradientA,
    required this.gradientB,
    required this.reshow,
    required this.dismissible,
    required this.isHidden,
    required this.audienceMode,
    required this.groupIds,
    required this.userIds,
    required this.startsAt,
    required this.endsAt,
    required this.ctaAction,
    required this.actionSelection,
    required this.imageIntent,
    required this.iconIntent,
    required this.homeSlot,
    required this.cardVariant,
    required this.gradientDirection,
  });

  final String title;
  final String subtitle;
  final String ctaLabel;
  final String ctaRoute;
  final String ctaUrl;
  final String iconKey;
  final String gradientA;
  final String gradientB;
  final String reshow;
  final bool dismissible;
  final bool isHidden;
  final String audienceMode;
  final List<String> groupIds;
  final List<String> userIds;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String ctaAction;
  final ContentActionSelection actionSelection;
  final ContentMediaIntentState imageIntent;
  final ContentMediaIntentState iconIntent;
  final ContentHomeSlot homeSlot;
  final ContentCardVariant cardVariant;
  final int gradientDirection;

  @override
  bool operator ==(Object other) {
    return other is _EditorSnapshot &&
        other.title == title &&
        other.subtitle == subtitle &&
        other.ctaLabel == ctaLabel &&
        other.ctaRoute == ctaRoute &&
        other.ctaUrl == ctaUrl &&
        other.iconKey == iconKey &&
        other.gradientA == gradientA &&
        other.gradientB == gradientB &&
        other.reshow == reshow &&
        other.dismissible == dismissible &&
        other.isHidden == isHidden &&
        other.audienceMode == audienceMode &&
        _listEq(other.groupIds, groupIds) &&
        _listEq(other.userIds, userIds) &&
        other.startsAt == startsAt &&
        other.endsAt == endsAt &&
        other.ctaAction == ctaAction &&
        other.actionSelection == actionSelection &&
        other.imageIntent == imageIntent &&
        other.iconIntent == iconIntent &&
        other.homeSlot == homeSlot &&
        other.cardVariant == cardVariant &&
        other.gradientDirection == gradientDirection;
  }

  @override
  int get hashCode => Object.hashAll([
    title,
    subtitle,
    ctaLabel,
    ctaRoute,
    ctaUrl,
    iconKey,
    gradientA,
    gradientB,
    reshow,
    dismissible,
    isHidden,
    audienceMode,
    Object.hashAll(groupIds),
    Object.hashAll(userIds),
    startsAt,
    endsAt,
    ctaAction,
    actionSelection,
    imageIntent,
    iconIntent,
    homeSlot,
    cardVariant,
    gradientDirection,
  ]);
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _HomePromoPhonePreview extends StatefulWidget {
  const _HomePromoPhonePreview({
    required this.placements,
    required this.news,
    required this.selectedId,
    this.onPlacementsBuilt,
  });

  final List<StudentHomePromoPlacement> placements;
  final List<StudentHomeNews> news;
  final String? selectedId;
  final VoidCallback? onPlacementsBuilt;

  @override
  State<_HomePromoPhonePreview> createState() => _HomePromoPhonePreviewState();
}

class _HomePromoPhonePreviewState extends State<_HomePromoPhonePreview> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onPlacementsBuilt?.call();
    });
  }

  @override
  void didUpdateWidget(covariant _HomePromoPhonePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedId != oldWidget.selectedId ||
        widget.placements.length != oldWidget.placements.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onPlacementsBuilt?.call();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final previewData = StudentHomeData(
      profile: const StudentHomeProfile(name: 'Минь', groupName: '1-См(ВВ)-2'),
      currentDate: now,
      lessons: const [
        StudentHomeLesson(
          subject: 'Базы данных',
          start: TimeOfDay(hour: 10, minute: 0),
          pairNumber: 2,
          room: '203',
          teacher: 'М. С. Лебедев',
        ),
        StudentHomeLesson(
          subject: 'Информационная безопасность',
          start: TimeOfDay(hour: 12, minute: 0),
          pairNumber: 3,
          room: '410',
          teacher: 'О. А. Морозова',
        ),
      ],
      assignments: const [
        StudentHomeAssignment(
          id: 'preview-assignment-1',
          title: 'Подготовить отчёт по лабораторной работе',
          subject: 'Базы данных',
          deadline: '23 июл.',
        ),
        StudentHomeAssignment(
          id: 'preview-assignment-2',
          title: 'Повторить материалы к семинару',
          subject: 'Информационная безопасность',
          deadline: '25 июл.',
          status: StudentHomeAssignmentStatus.inProgress,
        ),
      ],
      news: widget.news,
      totalLessonsToday: 2,
      assignmentsCount: 2,
    );

    return StudentHomeView(
      data: previewData,
      notificationCount: 3,
      hideHomePromo: widget.placements.isEmpty,
      homePromoPlacements: widget.placements,
      bottomNavigationBar: StudentBottomNav(
        currentIndex: 0,
        items: studentBottomNavItems,
        onTap: (_) {},
      ),
    );
  }
}

class _ImageSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE9EAF1),
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
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
    required this.titleController,
    required this.subtitleController,
    required this.iconController,
    required this.gradientAController,
    required this.gradientBController,
    required this.ctaLabelController,
    required this.ctaRouteController,
    required this.ctaUrlController,
    required this.reshowController,
    required this.dismissible,
    required this.isHidden,
    required this.audienceMode,
    required this.groupIds,
    required this.userIds,
    required this.audiencePreview,
    required this.ctaAction,
    required this.actionSelection,
    required this.loadChatOptions,
    required this.gradientDirection,
    required this.homeSlot,
    required this.cardVariant,
    required this.onHomeSlotChanged,
    required this.onCardVariantChanged,
    required this.onGradientDirectionChanged,
    required this.onActionSelectionChanged,
    required this.startsAt,
    required this.endsAt,
    required this.imageBytes,
    required this.imageLoading,
    required this.imageError,
    required this.iconBytes,
    required this.iconLoading,
    required this.iconError,
    required this.studentsRepository,
    required this.onChanged,
    required this.onDismissibleChanged,
    required this.onHiddenChanged,
    required this.onAudienceModeChanged,
    required this.onAudienceSelectionChanged,
    required this.onPickImage,
    required this.onClearImage,
    required this.onPickIcon,
    required this.onClearIcon,
    required this.onPreviewAudience,
    required this.onPickDate,
    required this.onClearStarts,
    required this.onClearEnds,
    required this.onDuplicate,
    required this.onArchive,
    required this.onRestoreArchived,
    required this.onSafeDelete,
    required this.onPromoteDemo,
    this.onBeginEdit,
    required this.publishedCount,
  });

  final HomePromoItem selected;
  final bool canWrite;
  final bool canPublish;
  final bool editingWorkingDraft;
  final bool busy;
  final TextEditingController titleController;
  final TextEditingController subtitleController;
  final TextEditingController iconController;
  final TextEditingController gradientAController;
  final TextEditingController gradientBController;
  final TextEditingController ctaLabelController;
  final TextEditingController ctaRouteController;
  final TextEditingController ctaUrlController;
  final TextEditingController reshowController;
  final bool dismissible;
  final bool isHidden;
  final String audienceMode;
  final List<String> groupIds;
  final List<String> userIds;
  final HomePromoAudiencePreview? audiencePreview;
  final String ctaAction;
  final ContentActionSelection actionSelection;
  final Future<List<ContentActionTargetOption>> Function(String query)
  loadChatOptions;
  final int gradientDirection;
  final ContentHomeSlot homeSlot;
  final ContentCardVariant cardVariant;
  final ValueChanged<ContentHomeSlot> onHomeSlotChanged;
  final ValueChanged<ContentCardVariant> onCardVariantChanged;
  final ValueChanged<int> onGradientDirectionChanged;
  final ValueChanged<ContentActionSelection> onActionSelectionChanged;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final Uint8List? imageBytes;
  final bool imageLoading;
  final String? imageError;
  final Uint8List? iconBytes;
  final bool iconLoading;
  final String? iconError;
  final StudentsRepository studentsRepository;
  final VoidCallback onChanged;
  final ValueChanged<bool> onDismissibleChanged;
  final ValueChanged<bool> onHiddenChanged;
  final ValueChanged<String> onAudienceModeChanged;
  final void Function({
    required List<String> groupIds,
    required List<String> userIds,
  })
  onAudienceSelectionChanged;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onPickIcon;
  final VoidCallback onClearIcon;
  final VoidCallback onPreviewAudience;
  final Future<void> Function({required bool starts}) onPickDate;
  final VoidCallback onClearStarts;
  final VoidCallback onClearEnds;
  final VoidCallback onDuplicate;
  final VoidCallback? onArchive;
  final VoidCallback? onRestoreArchived;
  final VoidCallback? onSafeDelete;
  final VoidCallback? onPromoteDemo;
  final VoidCallback? onBeginEdit;
  final int publishedCount;

  bool get _editable => canWrite && (selected.isDraft || editingWorkingDraft);

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _textField(titleController, 'Заголовок'),
          _textField(subtitleController, 'Подзаголовок', maxLines: 3),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContentIconPickerField(
              selectedKey: iconController.text.trim().isEmpty
                  ? null
                  : iconController.text.trim(),
              enabled: _editable,
              onChanged: (key) {
                iconController.text = key ?? '';
                onChanged();
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Своя иконка (PNG/WebP) имеет приоритет над встроенной.',
              style: TextStyle(color: Color(0xFF5C6370), fontSize: 12),
            ),
          ),
          if (iconLoading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 48,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          else if (iconBytes != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  iconBytes!,
                  height: 48,
                  width: 48,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          if (iconError != null) ...[
            const SizedBox(height: 4),
            Text(iconError!, style: const TextStyle(color: Color(0xFFB3261E))),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _editable ? onPickIcon : null,
                icon: const Icon(Icons.upload_rounded),
                label: const Text('Загрузить свою'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _editable &&
                        (iconBytes != null ||
                            selected.payload.iconAssetId != null)
                    ? onClearIcon
                    : null,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Убрать иконку'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContentGradientField(
              colorA: gradientAController.text,
              colorB: gradientBController.text,
              directionDegrees: gradientDirection,
              enabled: _editable,
              onColorAChanged: (value) {
                gradientAController.text = value;
                onChanged();
              },
              onColorBChanged: (value) {
                gradientBController.text = value;
                onChanged();
              },
              onDirectionChanged: onGradientDirectionChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContentPlacementSlotPicker(
              selected: homeSlot,
              enabled: _editable,
              onChanged: onHomeSlotChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContentCardVariantPicker(
              selected: cardVariant,
              enabled: _editable,
              onChanged: onCardVariantChanged,
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              'Schema v2: слот и вариант сохраняются в черновик. '
              'Публикация v2 заблокирована на сервере до релиза Mobile.',
              style: TextStyle(color: Color(0xFF5C6370), fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Text('Иллюстрация', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          if (imageLoading)
            _ImageSkeleton()
          else if (imageBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                imageBytes!,
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          if (imageError != null) ...[
            const SizedBox(height: 6),
            Text(imageError!, style: const TextStyle(color: Color(0xFFB3261E))),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _editable ? onPickImage : null,
                icon: const Icon(Icons.upload_rounded),
                label: const Text('Загрузить'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _editable &&
                        (imageBytes != null ||
                            selected.payload.imageAssetId != null)
                    ? onClearImage
                    : null,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Убрать'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _textField(ctaLabelController, 'Текст кнопки'),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ContentActionPicker(
              selection: actionSelection,
              enabled: _editable,
              allowedKinds: const [
                ContentActionKind.appScreen,
                ContentActionKind.referenceArticle,
                ContentActionKind.subject,
                ContentActionKind.vacancy,
                ContentActionKind.externalUrl,
                ContentActionKind.chat,
                ContentActionKind.none,
              ],
              loadChatOptions: loadChatOptions,
              onChanged: onActionSelectionChanged,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Можно закрыть'),
            value: dismissible,
            onChanged: _editable ? onDismissibleChanged : null,
          ),
          if (dismissible)
            _textField(reshowController, 'Повторный показ через (часы)'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Временно скрыть'),
            subtitle: const Text(
              'Скрытая карточка не попадает в ленту студента',
            ),
            value: isHidden,
            onChanged: _editable ? onHiddenChanged : null,
          ),
          const Divider(height: 24),
          Text(
            'Аудитория',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: audienceMode,
            decoration: const InputDecoration(labelText: 'Кому показывать'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Всем')),
              DropdownMenuItem(value: 'groups', child: Text('Группам')),
              DropdownMenuItem(value: 'users', child: Text('Пользователям')),
              DropdownMenuItem(
                value: 'groups_and_users',
                child: Text('Группам и пользователям'),
              ),
            ],
            onChanged: !_editable
                ? null
                : (value) => onAudienceModeChanged(value ?? 'all'),
          ),
          ContentAudienceSelectors(
            studentsRepository: studentsRepository,
            audienceMode: audienceMode,
            selectedGroupIds: groupIds,
            selectedUserIds: userIds,
            enabled: _editable,
            onChanged: onAudienceSelectionChanged,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: busy ? null : onPreviewAudience,
            icon: const Icon(Icons.groups_rounded),
            label: Text(
              audiencePreview == null
                  ? 'Предпросмотр охвата'
                  : 'Охват: ${audiencePreview!.recipientCount}',
            ),
          ),
          // Masked per-user lens RPC (`admin_preview_content_audience_lens`) exists
          // in stage14_1_2 migration; full lens UI deferred to a follow-up substage.
          const Divider(height: 24),
          Text(
            'Расписание',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'С: ${startsAt?.toLocal().toString().split(' ').first ?? '—'}',
            ),
            trailing: Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _editable ? () => onPickDate(starts: true) : null,
                  child: const Text('Выбрать'),
                ),
                TextButton(
                  onPressed: _editable ? onClearStarts : null,
                  child: const Text('Сброс'),
                ),
              ],
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'До: ${endsAt?.toLocal().toString().split(' ').first ?? '—'}',
            ),
            trailing: Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _editable ? () => onPickDate(starts: false) : null,
                  child: const Text('Выбрать'),
                ),
                TextButton(
                  onPressed: _editable ? onClearEnds : null,
                  child: const Text('Сброс'),
                ),
              ],
            ),
          ),
          ContentTechnicalPanel(
            children: [
              _textField(iconController, 'icon_key'),
              _textField(gradientAController, 'gradient · HEX 1'),
              _textField(gradientBController, 'gradient · HEX 2'),
              if (ctaAction == 'route')
                _textField(ctaRouteController, 'cta_route')
              else
                _textField(ctaUrlController, 'cta_url'),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Версия строки'),
                subtitle: Text('${selected.rowVersion}'),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Шаблон'),
                subtitle: Text(selected.templateKey),
              ),
              if (selected.legacyKey != null)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Legacy key'),
                  subtitle: Text(selected.legacyKey!),
                ),
            ],
          ),
          const Divider(height: 24),
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
              OutlinedButton.icon(
                onPressed: busy || !_editable ? null : onDuplicate,
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Дублировать'),
              ),
              if (onPromoteDemo != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onPromoteDemo,
                  icon: const Icon(Icons.upgrade_rounded),
                  label: const Text('Сделать обычной'),
                ),
              if (onArchive != null)
                OutlinedButton.icon(
                  onPressed: busy || !canPublish ? null : onArchive,
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('В архив'),
                ),
              if (onRestoreArchived != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onRestoreArchived,
                  icon: const Icon(Icons.unarchive_outlined),
                  label: const Text('Восстановить'),
                ),
              if (onSafeDelete != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onSafeDelete,
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Удалить навсегда'),
                ),
            ],
          ),
          if (publishedCount > 0 && selected.isDraft)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Опубликованных карточек: $publishedCount',
                style: const TextStyle(color: Color(0xFF5C6370), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        enabled: _editable,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

class _VersionHistoryDialog extends StatelessWidget {
  const _VersionHistoryDialog({required this.versions});

  final List<HomePromoVersionInfo> versions;

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
