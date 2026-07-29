import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import 'home_promo_item.dart';
import 'home_promo_repository.dart';
import 'supabase_home_promo_repository.dart';

/// Admin editor for managed Home promo (`home_promo_v1`).
///
/// Preview uses the same [StudentHomePromoCard] as Mobile.
class HomePromoEditorScreen extends StatefulWidget {
  const HomePromoEditorScreen({
    super.key,
    this.repository,
    this.session,
  });

  final HomePromoRepository? repository;
  final AdminSessionController? session;

  @override
  State<HomePromoEditorScreen> createState() => _HomePromoEditorScreenState();
}

class _HomePromoEditorScreenState extends State<HomePromoEditorScreen> {
  late final HomePromoRepository _repository =
      widget.repository ?? _defaultRepo();

  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  final _ctaLabelController = TextEditingController();
  final _ctaRouteController = TextEditingController();
  final _ctaUrlController = TextEditingController();
  final _iconController = TextEditingController(text: 'psychology');
  final _gradientAController = TextEditingController(text: '#FFFBFF');
  final _gradientBController = TextEditingController(text: '#F3EEF9');
  final _imageAssetController = TextEditingController();
  final _groupIdsController = TextEditingController();
  final _userIdsController = TextEditingController();
  final _reshowController = TextEditingController();

  List<HomePromoItem> _items = [];
  String? _selectedId;
  bool _loading = true;
  bool _busy = false;
  bool _dismissible = true;
  String _audienceMode = 'all';
  String _origin = 'admin';
  DateTime? _startsAt;
  DateTime? _endsAt;
  int _sortOrder = 0;
  String? _banner;
  String? _loadError;

  HomePromoItem? get _selected {
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

  HomePromoRepository _defaultRepo() {
    if (AdminBackendConfig.isDemoMode) return LocalHomePromoRepository();
    final client = _tryClient();
    if (client == null) return LocalHomePromoRepository();
    return SupabaseHomePromoRepository(client: client);
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
    _iconController.dispose();
    _gradientAController.dispose();
    _gradientBController.dispose();
    _imageAssetController.dispose();
    _groupIdsController.dispose();
    _userIdsController.dispose();
    _reshowController.dispose();
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

  void _bind(HomePromoItem item) {
    final p = item.payload;
    _titleController.text = p.title;
    _subtitleController.text = p.subtitle;
    _ctaLabelController.text = p.ctaLabel;
    _ctaRouteController.text = p.ctaRoute ?? '';
    _ctaUrlController.text = p.ctaUrl ?? '';
    _iconController.text = p.iconKey;
    _gradientAController.text = _hex(p.gradientColors.first);
    _gradientBController.text = _hex(
      p.gradientColors.length > 1 ? p.gradientColors[1] : p.gradientColors.first,
    );
    _imageAssetController.text = p.imageAssetId ?? '';
    _reshowController.text = p.reshowAfterHours?.toString() ?? '';
    _dismissible = p.dismissible;
    _audienceMode = item.audienceMode;
    _origin = switch (item.origin) {
      ContentOrigin.demo => 'demo',
      ContentOrigin.admin => 'admin',
      ContentOrigin.importSource => 'import',
      ContentOrigin.userSubmission => 'user_submission',
    };
    _startsAt = item.startsAt;
    _endsAt = item.endsAt;
    _sortOrder = item.sortOrder;
    _groupIdsController.text = item.audienceGroupIds.join(', ');
    _userIdsController.text = item.audienceUserIds.join(', ');
    setState(() {});
  }

  String _hex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  HomePromoPayload? _draftPayload() {
    final reshowRaw = _reshowController.text.trim();
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
      if (_ctaRouteController.text.trim().isNotEmpty)
        'cta_route': _ctaRouteController.text.trim(),
      if (_ctaUrlController.text.trim().isNotEmpty)
        'cta_url': _ctaUrlController.text.trim(),
      // image_asset_id editing disabled until media presentation path exists.
      if (reshowRaw.isNotEmpty) 'reshow_after_hours': int.tryParse(reshowRaw),
    };
    final parsed = HomePromoPayload.tryParse(map);
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
            'Нельзя создать: проверьте обязательные поля (fail-closed).',
      );
      return;
    }
    await _run(() async {
      final origin = ContentOrigin.tryParse(_origin);
      if (origin != ContentOrigin.admin && origin != ContentOrigin.demo) {
        setState(
          () => _banner =
              'Ручное создание только с origin admin|demo. '
              'import/user_submission — read-only provenance.',
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
      setState(() => _selectedId = created.id);
      final selected = _selected;
      if (selected != null) _bind(selected);
      setState(() => _banner = 'Черновик создан.');
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
      if (nextOrigin != ContentOrigin.admin &&
          nextOrigin != ContentOrigin.demo &&
          nextOrigin != selected.origin) {
        setState(
          () => _banner =
              'Нельзя вручную назначить origin import/user_submission.',
        );
        return;
      }
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
        sortOrder: _sortOrder,
        expectedRowVersion: next.rowVersion,
      );
      next = await _repository.setAudience(
        id: next.id,
        audienceMode: _audienceMode,
        groupIds: _splitIds(_groupIdsController.text),
        userIds: _splitIds(_userIdsController.text),
        expectedRowVersion: next.rowVersion,
      );
      await _reload();
      if (!mounted) return;
      setState(() {
        _selectedId = next.id;
        _banner = 'Сохранено.';
      });
      final rebound = _selected;
      if (rebound != null) _bind(rebound);
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

  List<String> _splitIds(String raw) {
    return raw
        .split(RegExp(r'[\s,;]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _reload, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    final selected = _selected;
    final previewPayload =
        _draftPayload() ?? HomePromoPayload.demoStuckWithAssignment;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 280,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Главная · promo',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                if (_canWrite)
                  FilledButton.icon(
                    onPressed: _busy ? null : _create,
                    icon: const Icon(Icons.add),
                    label: const Text('Новый черновик'),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final selectedItem = item.id == _selectedId;
                      return Material(
                        color: selectedItem
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.08)
                            : Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: ListTile(
                          title: Text(item.title),
                          subtitle: Text(
                            '${homePromoStatusWire(item.status)} · ${item.origin.labelRu}',
                          ),
                          onTap: () {
                            setState(() => _selectedId = item.id);
                            _bind(item);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: selected == null
                ? const Center(child: Text('Выберите или создайте карточку.'))
                : ListView(
                    children: [
                      if (_banner != null) ...[
                        Text(_banner!),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        'Preview (тот же renderer, что Mobile)',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: StudentHomePromoCard(
                          payload: previewPayload,
                          showDemoBadge: _origin == 'demo',
                          padding: EdgeInsets.zero,
                          onTap: () {},
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_canWrite)
                            FilledButton(
                              onPressed: _busy ||
                                      selected.status != HomePromoStatus.draft
                                  ? null
                                  : _save,
                              child: const Text('Сохранить черновик'),
                            ),
                          if (_canPublish)
                            FilledButton.tonal(
                              onPressed: _busy ||
                                      selected.status != HomePromoStatus.draft
                                  ? null
                                  : _publish,
                              child: const Text('Опубликовать'),
                            ),
                          if (_canPublish)
                            OutlinedButton(
                              onPressed: _busy ||
                                      selected.status == HomePromoStatus.archived
                                  ? null
                                  : _archive,
                              child: const Text('В архив'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Статус: ${homePromoStatusWire(selected.status)} · '
                        'row_version=${selected.rowVersion}',
                      ),
                      const SizedBox(height: 12),
                      _field(_titleController, 'Заголовок'),
                      _field(_subtitleController, 'Подзаголовок', maxLines: 3),
                      _field(_iconController, 'Иконка (icon_key)'),
                      _field(_gradientAController, 'Градиент цвет 1 (#RRGGBB)'),
                      _field(_gradientBController, 'Градиент цвет 2 (#RRGGBB)'),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Иллюстрация (image_asset_id)',
                            helperText:
                                'Поле отключено до signed-URL/media path; '
                                'renderer пока не показывает image_asset_id.',
                          ),
                          child: Text(
                            _imageAssetController.text.trim().isEmpty
                                ? '— не задано —'
                                : _imageAssetController.text.trim(),
                          ),
                        ),
                      ),
                      _field(_ctaLabelController, 'CTA'),
                      _field(_ctaRouteController, 'Внутренний маршрут'),
                      _field(
                        _ctaUrlController,
                        'Внешняя ссылка (http/https)',
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Можно закрыть'),
                        value: _dismissible,
                        onChanged: !_canWrite
                            ? null
                            : (v) => setState(() => _dismissible = v),
                      ),
                      _field(
                        _reshowController,
                        'Повторный показ через (часы)',
                      ),
                      if (_origin == 'import' ||
                          _origin == 'user_submission')
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Origin (read-only provenance)',
                            helperText:
                                'import/user_submission нельзя назначить вручную.',
                          ),
                          child: Text(_origin),
                        )
                      else
                        DropdownButtonFormField<String>(
                          initialValue:
                              _origin == 'demo' ? 'demo' : 'admin',
                          decoration:
                              const InputDecoration(labelText: 'Origin'),
                          items: const [
                            DropdownMenuItem(
                              value: 'admin',
                              child: Text('admin'),
                            ),
                            DropdownMenuItem(
                              value: 'demo',
                              child: Text('demo'),
                            ),
                          ],
                          onChanged: !_canWrite ||
                                  selected.status != HomePromoStatus.draft
                              ? null
                              : (v) =>
                                  setState(() => _origin = v ?? 'admin'),
                        ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: _audienceMode,
                        decoration:
                            const InputDecoration(labelText: 'Аудитория'),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('all')),
                          DropdownMenuItem(
                            value: 'groups',
                            child: Text('groups'),
                          ),
                          DropdownMenuItem(
                            value: 'users',
                            child: Text('users'),
                          ),
                          DropdownMenuItem(
                            value: 'groups_and_users',
                            child: Text('groups_and_users'),
                          ),
                        ],
                        onChanged: !_canWrite ||
                                selected.status != HomePromoStatus.draft
                            ? null
                            : (v) =>
                                setState(() => _audienceMode = v ?? 'all'),
                      ),
                      _field(
                        _groupIdsController,
                        'Group IDs (comma-separated UUID)',
                      ),
                      _field(
                        _userIdsController,
                        'User IDs (comma-separated UUID)',
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Период с: ${_startsAt?.toLocal().toString().split(' ').first ?? '—'}',
                        ),
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: !_canWrite
                                  ? null
                                  : () => _pickDate(starts: true),
                              child: const Text('Выбрать'),
                            ),
                            TextButton(
                              onPressed: !_canWrite
                                  ? null
                                  : () => setState(() => _startsAt = null),
                              child: const Text('Сброс'),
                            ),
                          ],
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          'Период до: ${_endsAt?.toLocal().toString().split(' ').first ?? '—'}',
                        ),
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: !_canWrite
                                  ? null
                                  : () => _pickDate(starts: false),
                              child: const Text('Выбрать'),
                            ),
                            TextButton(
                              onPressed: !_canWrite
                                  ? null
                                  : () => setState(() => _endsAt = null),
                              child: const Text('Сброс'),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        children: [
                          const Text('Порядок'),
                          const SizedBox(width: 12),
                          IconButton(
                            onPressed: !_canWrite
                                ? null
                                : () => setState(
                                      () => _sortOrder =
                                          (_sortOrder - 1).clamp(0, 9999),
                                    ),
                            icon: const Icon(Icons.remove),
                          ),
                          Text('$_sortOrder'),
                          IconButton(
                            onPressed: !_canWrite
                                ? null
                                : () => setState(() => _sortOrder += 1),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        // Allow typing for live preview; persist remains draft-only via Save.
        enabled: _canWrite,
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}
