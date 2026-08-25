import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../../academic/students/students_repository.dart';
import 'content_audience_selectors.dart';
import 'profile_feed_item.dart';
import 'profile_feed_repository.dart';
import 'supabase_profile_feed_repository.dart';

/// Admin editor for managed Profile feed (`profile_feed_card_v1`).
///
/// Create always sets placement `profile_feed` explicitly.
/// No news import/copy path.
class ProfileFeedEditorScreen extends StatefulWidget {
  const ProfileFeedEditorScreen({
    super.key,
    this.repository,
    this.session,
  });

  final ProfileFeedRepository? repository;
  final AdminSessionController? session;

  @override
  State<ProfileFeedEditorScreen> createState() =>
      _ProfileFeedEditorScreenState();
}

class _ProfileFeedEditorScreenState extends State<ProfileFeedEditorScreen> {
  late final ProfileFeedRepository _repository =
      widget.repository ?? _defaultRepo();

  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  final _ctaLabelController = TextEditingController();
  final _ctaRouteController = TextEditingController();
  final _ctaUrlController = TextEditingController();
  final _sortOrderController = TextEditingController(text: '0');

  List<ProfileFeedItem> _items = [];
  String? _selectedId;
  bool _loading = true;
  bool _busy = false;
  String _audienceMode = 'all';
  String _origin = 'admin';
  DateTime? _startsAt;
  DateTime? _endsAt;
  List<String> _groupIds = const [];
  List<String> _userIds = const [];
  ProfileFeedAudiencePreview? _audiencePreview;
  String? _banner;
  String? _loadError;
  late final StudentsRepository _studentsRepository = _defaultStudentsRepo();

  ProfileFeedItem? get _selected {
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

  SupabaseClient? _tryClient() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  ProfileFeedRepository _defaultRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalProfileFeedRepository();
    final client = _tryClient();
    if (client == null) return LocalProfileFeedRepository();
    return SupabaseProfileFeedRepository(client: client);
  }

  StudentsRepository _defaultStudentsRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalStudentsRepository();
    final client = _tryClient();
    if (client == null) return LocalStudentsRepository();
    return SupabaseStudentsRepository(client: client);
  }

  String _statusRu(ProfileFeedStatus status) {
    switch (status) {
      case ProfileFeedStatus.draft:
        return 'Черновик';
      case ProfileFeedStatus.published:
        return 'Опубликовано';
      case ProfileFeedStatus.archived:
        return 'В архиве';
    }
  }

  String _audienceModeRu(String mode) {
    switch (mode) {
      case 'groups':
        return 'Группы';
      case 'users':
        return 'Пользователи';
      case 'groups_and_users':
        return 'Группы и пользователи';
      default:
        return 'Все';
    }
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    _ctaLabelController.dispose();
    _ctaRouteController.dispose();
    _ctaUrlController.dispose();
    _sortOrderController.dispose();
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
      if (selected != null) _bind(selected);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  void _bind(ProfileFeedItem item) {
    final p = item.payload;
    _titleController.text = p.title;
    _subtitleController.text = p.subtitle;
    _ctaLabelController.text = p.ctaLabel;
    _ctaRouteController.text = p.ctaRoute ?? '';
    _ctaUrlController.text = p.ctaUrl ?? '';
    _audienceMode = item.audienceMode;
    _origin = switch (item.origin) {
      ContentOrigin.demo => 'demo',
      ContentOrigin.admin => 'admin',
      ContentOrigin.importSource => 'import',
      ContentOrigin.userSubmission => 'user_submission',
    };
    _startsAt = item.startsAt;
    _endsAt = item.endsAt;
    _sortOrderController.text = '${item.sortOrder}';
    _groupIds = item.audienceGroupIds;
    _userIds = item.audienceUserIds;
    _audiencePreview = null;
    setState(() {});
  }

  ProfileFeedPayload? _draftPayload() {
    final map = <String, dynamic>{
      'title': _titleController.text.trim(),
      'subtitle': _subtitleController.text.trim(),
      'cta_label': _ctaLabelController.text.trim(),
      if (_ctaRouteController.text.trim().isNotEmpty)
        'cta_route': _ctaRouteController.text.trim(),
      if (_ctaUrlController.text.trim().isNotEmpty)
        'cta_url': _ctaUrlController.text.trim(),
    };
    final parsed = ProfileFeedPayload.tryParse(map);
    if (parsed == null) return null;
    final existingImage = _selected?.payload.imageAssetId;
    if (existingImage == null || existingImage.isEmpty) return parsed;
    return parsed.copyWith(imageAssetId: existingImage);
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
    final payload = _draftPayload();
    if (payload == null) {
      setState(
        () => _banner =
            'Нельзя создать: заполните заголовок, подзаголовок и CTA '
            '(fail-closed, запись не создана).',
      );
      return;
    }
    await _run(() async {
      final origin = ContentOrigin.tryParse(_origin);
      if (origin != ContentOrigin.admin && origin != ContentOrigin.demo) {
        setState(
          () => _banner =
              'Ручное создание только с origin admin|demo. '
              'Новости сюда не копируются.',
        );
        return;
      }
      final created = await _repository.createDraft(
        payload: payload,
        title: payload.title,
        origin: origin!,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = created.id;
        _banner =
            'Черновик создан: шаблон «карточка ленты профиля», '
            'размещение «лента профиля» (явно).';
      });
      final selected = _selected;
      if (selected != null) _bind(selected);
    });
  }

  Future<void> _save() async {
    final selected = _selected;
    if (selected == null) return;
    final payload = _draftPayload();
    if (payload == null) {
      setState(() => _banner = 'Проверьте поля карточки (fail-closed parse).');
      return;
    }
    await _run(() async {
      final nextOrigin =
          (selected.origin == ContentOrigin.importSource ||
                  selected.origin == ContentOrigin.userSubmission)
              ? selected.origin
              : (ContentOrigin.tryParse(_origin) ?? selected.origin);
      var next = selected.copyWith(
        title: payload.title,
        payload: payload,
        origin: nextOrigin,
        startsAt: _startsAt,
        endsAt: _endsAt,
        clearStartsAt: _startsAt == null,
        clearEndsAt: _endsAt == null,
      );
      next = await _repository.updateDraft(next);
      next = await _repository.setPlacements(
        id: next.id,
        sortOrder: int.tryParse(_sortOrderController.text.trim()) ?? 0,
        expectedRowVersion: next.rowVersion,
      );
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

  bool get _audienceDirty {
    final selected = _selected;
    if (selected == null) return false;
    if (selected.audienceMode != _audienceMode) return true;
    if (!_sameIdSet(selected.audienceGroupIds, _groupIds)) return true;
    if (!_sameIdSet(selected.audienceUserIds, _userIds)) return true;
    return false;
  }

  bool _sameIdSet(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final left = {...a};
    final right = {...b};
    return left.length == right.length && left.containsAll(right);
  }

  Future<void> _previewAudience() async {
    final selected = _selected;
    if (selected == null) return;
    if (_audienceDirty) {
      setState(
        () => _banner =
            'Сначала сохраните аудиторию — Preview считает только '
            'сохранённые данные на сервере.',
      );
      return;
    }
    await _run(() async {
      final preview = await _repository.previewAudience(selected.id);
      if (!mounted) return;
      setState(() {
        _audiencePreview = preview;
        _banner =
            'Preview аудитории: ${preview.recipientCount} получателей '
            '(${_audienceModeRu(preview.audienceMode)}; '
            'групп: ${preview.groupCount}; '
            'явных пользователей: ${preview.explicitUserCount}). '
            'Список студентов не показывается.';
      });
    });
  }

  Future<void> _publish() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      await _repository.publish(selected.id, selected.rowVersion);
      await _reload();
      setState(() => _banner = 'Опубликовано.');
    });
  }

  Future<void> _archive() async {
    final selected = _selected;
    if (selected == null) return;
    await _run(() async {
      await _repository.archive(selected.id, selected.rowVersion);
      await _reload();
      setState(() => _banner = 'В архиве.');
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
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!),
            const SizedBox(height: 12),
            FilledButton(onPressed: _reload, child: const Text('Повторить')),
          ],
        ),
      );
    }

    final selected = _selected;
    final preview = _draftPayload() ?? ProfileFeedPayload.demoFeed.first;
    final draftOnly =
        selected == null || selected.status == ProfileFeedStatus.draft;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Лента профиля',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Только placement profile_feed / template '
                'profile_feed_card_v1. Новости не копируются.',
              ),
              const SizedBox(height: 12),
              if (_canWrite)
                FilledButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.add),
                  label: const Text('Новая карточка'),
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
                        '${_statusRu(item.status)} · '
                        '${item.origin.labelRu} · порядок ${item.sortOrder + 1}',
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
              ? const Center(child: Text('Создайте карточку ленты.'))
              : ListView(
                  children: [
                    if (_banner != null) ...[
                      Text(_banner!),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      'Preview (тот же виджет, что Mobile)',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 160,
                      child: StudentProfileFeedCard(
                        payload: preview,
                        showDemoBadge: selected.origin == ContentOrigin.demo,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _titleController,
                      decoration:
                          const InputDecoration(labelText: 'Заголовок'),
                      enabled: _canWrite && draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _subtitleController,
                      decoration:
                          const InputDecoration(labelText: 'Подзаголовок'),
                      enabled: _canWrite && draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _ctaLabelController,
                      decoration: const InputDecoration(labelText: 'CTA'),
                      enabled: _canWrite && draftOnly,
                      onChanged: (_) => setState(() {}),
                    ),
                    TextField(
                      controller: _ctaRouteController,
                      decoration: const InputDecoration(
                        labelText: 'Внутренний маршрут',
                      ),
                      enabled: _canWrite && draftOnly,
                    ),
                    TextField(
                      controller: _ctaUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Внешняя ссылка',
                      ),
                      enabled: _canWrite && draftOnly,
                    ),
                    const SizedBox(height: 8),
                    const InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Иллюстрация',
                        helperText:
                            'image_asset_id отключён до signed-URL path; '
                            'существующий id сохраняется при save.',
                      ),
                      child: Text('— не редактируется —'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _sortOrderController,
                      decoration: const InputDecoration(
                        labelText: 'Порядок (sort_order)',
                      ),
                      enabled: _canWrite && draftOnly,
                      keyboardType: TextInputType.number,
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey('audience-$_audienceMode'),
                      initialValue: _audienceMode,
                      decoration: const InputDecoration(
                        labelText: 'Аудитория',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Все'),
                        ),
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
                      onChanged: !_canWrite || !draftOnly
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _audienceMode = value;
                                _audiencePreview = null;
                              });
                            },
                    ),
                    const SizedBox(height: 8),
                    ContentAudienceSelectors(
                      studentsRepository: _studentsRepository,
                      audienceMode: _audienceMode,
                      selectedGroupIds: _groupIds,
                      selectedUserIds: _userIds,
                      enabled: _canWrite && draftOnly,
                      onChanged: ({
                        required groupIds,
                        required userIds,
                      }) {
                        setState(() {
                          _groupIds = groupIds;
                          _userIds = userIds;
                          _audiencePreview = null;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy || selected == null
                          ? null
                          : _previewAudience,
                      icon: const Icon(Icons.preview_outlined),
                      label: const Text('Preview аудитории'),
                    ),
                    if (_audiencePreview != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Получателей: ${_audiencePreview!.recipientCount}. '
                        'Групп в разбивке: ${_audiencePreview!.groupCount}. '
                        'Явных пользователей: '
                        '${_audiencePreview!.explicitUserCount}.',
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: !_canWrite || !draftOnly
                              ? null
                              : () => _pickDate(starts: true),
                          child: Text(
                            _startsAt == null
                                ? 'Начало (не задано)'
                                : 'Начало: ${_startsAt!.toIso8601String().substring(0, 10)}',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: !_canWrite || !draftOnly
                              ? null
                              : () => _pickDate(starts: false),
                          child: Text(
                            _endsAt == null
                                ? 'Конец (не задано)'
                                : 'Конец: ${_endsAt!.toIso8601String().substring(0, 10)}',
                          ),
                        ),
                        if (_canWrite && draftOnly)
                          TextButton(
                            onPressed: () => setState(() {
                              _startsAt = null;
                              _endsAt = null;
                            }),
                            child: const Text('Сбросить даты'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: !_canWrite || _busy || !draftOnly
                              ? null
                              : _save,
                          child: const Text('Сохранить'),
                        ),
                        FilledButton.tonal(
                          onPressed: !_canPublish ||
                                  _busy ||
                                  selected.status != ProfileFeedStatus.draft
                              ? null
                              : _publish,
                          child: const Text('Опубликовать'),
                        ),
                        OutlinedButton(
                          onPressed: !_canWrite ||
                                  _busy ||
                                  selected.status == ProfileFeedStatus.archived
                              ? null
                              : _archive,
                          child: const Text('В архив'),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
