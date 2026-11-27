import 'dart:async';

import 'package:flutter/material.dart';
import 'package:student_platform/src/core/attachment_storage_inventory.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';

/// Storage estimates and controls for the caches the app can manage.
class CacheDiagnosticsScreen extends StatefulWidget {
  const CacheDiagnosticsScreen(
      {super.key,
      this.measure,
      this.measureAttachments,
      this.clearNews,
      this.canAccess,
      this.budget,
      this.debugCapabilities,
      this.timeout = const Duration(seconds: 5)});
  @visibleForTesting
  final Future<InventorySnapshot> Function()? measure;
  @visibleForTesting
  final Future<AttachmentStorageReport> Function()? measureAttachments;
  @visibleForTesting
  final Future<PublicNewsClearResult> Function()? clearNews;

  /// Rechecks the original offline route permit before dispatching an action.
  final bool Function()? canAccess;
  @visibleForTesting
  final OptionalImageCacheBudget? budget;
  @visibleForTesting
  final SessionCapabilities? debugCapabilities;
  @visibleForTesting
  final Duration timeout;
  @override
  State<CacheDiagnosticsScreen> createState() => _CacheDiagnosticsScreenState();
}

class _CacheDiagnosticsScreenState extends State<CacheDiagnosticsScreen> {
  bool get _accessible => mounted && (widget.canAccess?.call() ?? true);
  int _revision = 0;
  InventorySnapshot? _snapshot;
  int? _budgetObserved;
  int _budgetReserved = 0;
  bool _loading = true;
  bool _changing = false;
  bool _clearPending = false;
  String? _clearMessage;
  AttachmentStorageReport? _attachments;
  final ValueNotifier<int?> _logicalHistory = ValueNotifier<int?>(null);
  SessionCapabilities? _historyCapabilities;
  AuthSessionScope? _historyScope;
  Future<int?>? _historyPending;
  int _historyRevision = 0;
  @override
  void initState() {
    super.initState();
    ProjectChatServerCache.instanceChanges.addListener(_onCacheChanged);
    ProjectChatServerCache.snapshotChanges.addListener(_invalidateHistory);
    _measure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final caps =
        widget.debugCapabilities ?? SessionCapabilitiesHost.maybeOf(context);
    _bindCapabilities(caps);
  }

  @override
  void didUpdateWidget(covariant CacheDiagnosticsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.debugCapabilities, widget.debugCapabilities)) {
      _bindCapabilities(widget.debugCapabilities ??
          SessionCapabilitiesHost.maybeRead(context));
    }
  }

  void _bindCapabilities(SessionCapabilities? caps) {
    if (!identical(caps, _historyCapabilities)) {
      _historyCapabilities?.removeListener(_invalidateHistory);
      _historyCapabilities = caps;
      _historyCapabilities?.addListener(_invalidateHistory);
      _bindHistoryScope();
      _invalidateHistory();
      _startHistory();
    }
  }

  void _bindHistoryScope() {
    final next = ProjectChatServerCache.qaInstance?.scope;
    if (identical(next, _historyScope)) return;
    _historyScope?.removeListener(_invalidateHistory);
    _historyScope = next;
    _historyScope?.addListener(_invalidateHistory);
  }

  void _onCacheChanged() {
    _bindHistoryScope();
    _invalidateHistory();
  }

  void _invalidateHistory() {
    _historyRevision++;
    _logicalHistory.value = null;
  }

  void _startHistory() {
    _invalidateHistory();
    final cache = ProjectChatServerCache.qaInstance,
        caps = _historyCapabilities;
    if (cache == null || caps == null || _historyPending != null) return;
    final revision = _historyRevision;
    bool current() =>
        mounted &&
        revision == _historyRevision &&
        identical(ProjectChatServerCache.qaInstance, cache) &&
        identical(_historyCapabilities, caps);
    final raw = cache.readScopedLogicalHistory(caps, isCurrent: current);
    _historyPending = raw;
    unawaited(raw.then<void>((_) {
      if (identical(_historyPending, raw)) _historyPending = null;
    }, onError: (Object _, StackTrace __) {
      if (identical(_historyPending, raw)) _historyPending = null;
    }));
    unawaited(() async {
      try {
        final result = await raw.timeout(widget.timeout);
        if (current()) _logicalHistory.value = result;
      } catch (_) {
        if (current()) _invalidateHistory();
      }
    }());
  }

  @override
  void dispose() {
    _historyRevision++;
    ProjectChatServerCache.instanceChanges.removeListener(_onCacheChanged);
    ProjectChatServerCache.snapshotChanges.removeListener(_invalidateHistory);
    _historyCapabilities?.removeListener(_invalidateHistory);
    _historyScope?.removeListener(_invalidateHistory);
    _logicalHistory.dispose();
    super.dispose();
  }

  Future<void> _measure() async {
    if (!_accessible) return;
    final revision = ++_revision;
    if (_historyCapabilities != null) _startHistory();
    setState(() => _loading = true);
    final budget = widget.budget ??
        (widget.measure == null ? OptionalImageCacheBudget.instance : null);
    unawaited(_measurePart(widget.measureAttachments ??
            AttachmentStorageInventory.shared.collect)
        .then((value) {
      if (_accessible && revision == _revision) {
        setState(() => _attachments = value);
      }
    }));
    final (snapshot, budgetReady) = await (
      _measurePart(widget.measure ?? CacheInventoryCollector.shared.collect),
      _measurePart(() async {
        if (budget == null) return false;
        await Future.wait<void>(
            [budget.waitForPolicy(), budget.refreshForDisplay()]);
        return true;
      }),
    ).wait;
    if (!_accessible || revision != _revision) return;
    setState(() {
      _snapshot = snapshot;
      _budgetObserved = budgetReady == true ? budget?.observedBytes : null;
      _budgetReserved = budgetReady == true ? budget!.reservedBytes : 0;
      _loading = false;
    });
  }

  Future<T?> _measurePart<T>(Future<T> Function() measure) async {
    try {
      return await measure().timeout(widget.timeout);
    } catch (_) {
      return null;
    }
  }

  String _value(int? bytes) {
    if (bytes == null) return 'неизвестно';
    if (bytes < 1000) return '$bytes Б';
    if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} кБ';
    return '${(bytes / 1000000).toStringAsFixed(1)} МБ';
  }

  Future<void> _confirmClearNews() async {
    if (_clearPending || !_accessible) return;
    setState(() => _clearPending = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить копии изображений новостей?'),
          content: const Text(
              'Удалятся только временные копии изображений из текущих публичных новостей. При следующем открытии новости загрузят их из интернета.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Удалить копии')),
          ],
        ),
      );
      if (confirmed != true || !_accessible) return;
      setState(() => _clearMessage = 'Идёт очистка. Экран можно закрыть.');
      final clear =
          widget.clearNews ?? PublicNewsImageCache.shared.clearStoredCopies;
      final result = await clear();
      if (!_accessible) return;
      setState(() => _clearMessage = switch (result.status) {
            PublicNewsClearStatus.complete =>
              'Очистка завершена. Удалено файлов: ${result.filesRemoved}.',
            PublicNewsClearStatus.partial =>
              'Очистка завершена частично. Удалено файлов: ${result.filesRemoved}. Можно повторить.',
            PublicNewsClearStatus.unavailable =>
              'Не удалось подтвердить очистку. Попробуйте ещё раз.',
          });
      await _measure();
    } catch (_) {
      if (mounted) {
        setState(() => _clearMessage =
            'Не удалось подтвердить очистку. Попробуйте ещё раз.');
      }
    } finally {
      if (mounted) setState(() => _clearPending = false);
    }
  }

  Future<void> _chooseLimit(OptionalImageCacheBudget budget) async {
    if (!_accessible || _changing) return;
    final choice = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('Целевой лимит кэша'),
              children: [
                for (final bytes in [250000000, 500000000, 1000000000])
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, bytes),
                      child: Text(bytes == 1000000000
                          ? '1 ГБ'
                          : '${bytes ~/ 1000000} МБ'))
              ],
            ));
    if (!_accessible || choice == null) return;
    setState(() => _changing = true);
    final success = await budget.setLimit(choice);
    if (!_accessible) return;
    setState(() => _changing = false);
    if (!success)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Не удалось сохранить лимит. Попробуйте ещё раз.')));
    await _measure();
  }

  String _label(String name) => switch (name) {
        'public_news_blobs_v2' => 'Копии публичных новостей',
        'public_news_index_v2.db' => 'Индекс публичных новостей (DB/WAL/SHM)',
        'news_images_v1' => 'Кэш новостей (старый)',
        'guest_news_images_v1' => 'Кэш гостевых новостей (старый)',
        'content_media_images_v1' => 'Кэш материалов (старый)',
        'offline_chat_ordinary_v1.db' => 'База истории чатов (DB/WAL/SHM)',
        'forward_outbox_v1.db' => 'Очередь пересылки (DB/WAL/SHM)',
        'draft_recovery_v1.db' => 'Восстановление черновиков (DB/WAL/SHM)',
        'pinned_media_v1' => 'Сохранённые офлайн файлы',
        _ => 'Защита сохранённых файлов: $name',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final snapshot = _snapshot;
    final attachments = _attachments;
    final budget = widget.budget ?? OptionalImageCacheBudget.instance;
    final showBudget = widget.measure == null || widget.budget != null;
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 20;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Данные приложения'),
        toolbarHeight: largeText ? 76 : kToolbarHeight,
      ),
      body: SafeArea(
          top: false,
          child: LayoutBuilder(builder: (context, constraints) {
            final gutter = constraints.maxWidth > 592
                ? (constraints.maxWidth - 560) / 2
                : 16.0;
            return ListView(
              padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 24),
              children: [
                _StorageSection(
                  icon: Icons.storage_outlined,
                  title: 'Место на устройстве',
                  color: colors.primaryContainer,
                  children: [
                    if (showBudget) ...[
                      Text(
                          _budgetObserved == null
                              ? 'Нет оценки'
                              : _value(_budgetObserved),
                          style: theme.textTheme.headlineMedium?.copyWith(
                              color: colors.onPrimaryContainer,
                              fontWeight: FontWeight.w700)),
                      const Text('Учтённые копии новостей и материалов'),
                      const SizedBox(height: 6),
                    ],
                    Text('Частичная оценка',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: colors.onPrimaryContainer)),
                    const Text(
                        'Полный объём приложения доступен в настройках устройства.'),
                    if (_loading) ...[
                      const SizedBox(height: 8),
                      const Text('Подсчёт…'),
                    ] else if (snapshot == null) ...[
                      const SizedBox(height: 8),
                      const Text('Сейчас недоступно'),
                    ],
                  ],
                ),
                if (showBudget) ...[
                  const SizedBox(height: 12),
                  _StorageSection(
                    icon: Icons.tune_outlined,
                    title: 'Лимит кэша',
                    children: [
                      Text(budget.policyReady
                          ? 'Целевой лимит — ${_value(budget.limitBytes)}'
                          : 'Целевой лимит сейчас недоступен.'),
                      const Text(
                          'Лимит охватывает копии новостей и материалов и часть подтверждённой истории чатов.'),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _loading ||
                                _changing ||
                                budget.policyBusy ||
                                !_accessible
                            ? null
                            : () => _chooseLimit(budget),
                        child: const Text('Изменить целевой лимит',
                            textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                _StorageSection(
                  icon: Icons.attach_file,
                  title: 'Вложения чатов на устройстве',
                  children: [
                    Text(
                        'Скачанные вложения: ${_value(attachments?.downloadedFilesBytes)}'),
                    const Text(
                        'Оценка для всех аккаунтов на устройстве. Учитывается отдельно от лимита кэша.'),
                  ],
                ),
                const SizedBox(height: 12),
                _StorageSection(
                  icon: Icons.cleaning_services_outlined,
                  title: 'Очистка кэша',
                  children: [
                    const Text(
                        'Можно освободить место, удалив временные копии изображений из текущих публичных новостей.'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _clearPending || !_accessible
                          ? null
                          : _confirmClearNews,
                      child: const Text('Очистить кэш публичных новостей',
                          textAlign: TextAlign.center),
                    ),
                    if (_clearMessage != null)
                      Semantics(liveRegion: true, child: Text(_clearMessage!)),
                  ],
                ),
                const SizedBox(height: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: colors.outlineVariant)),
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: const Text('Дополнительно'),
                    subtitle:
                        const Text('История чатов, оценки и служебные файлы'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showBudget) ...[
                        Text(
                            'Резерв активных записей: ${_value(_budgetObserved == null ? null : _budgetReserved)}'),
                        if (budget.policyReady)
                          Text(
                              'Служебный запас включён в лимит: ${_value(budget.serviceReserveBytes)}'),
                        const SizedBox(height: 8),
                        const Text(
                            'При превышении лимита старая подтверждённая история чатов может очищаться в фоне при подключении к сети и доступности проверок. Черновики, неотправленные данные и сохранённые офлайн-файлы защищены от этой очистки.'),
                        const SizedBox(height: 12),
                      ],
                      for (final item in snapshot?.observations ??
                          const <InventoryObservation>[])
                        Text('${_label(item.name)}: ${_value(item.bytes)}'),
                      ValueListenableBuilder<int?>(
                        valueListenable: _logicalHistory,
                        builder: (_, value, __) => Text(
                            'Логический размер подтверждённой части истории: ${_value(value)}'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                          'Это не общий размер истории на диске и не объём, доступный для очистки. Некоторые общие или защищённые файлы могут учитываться повторно.'),
                      const SizedBox(height: 12),
                      Text(
                          'Рабочие файлы чатов и данные доступа: ${_value(attachments?.authorizedFilesBytes)}'),
                      Text(
                          'Копии для просмотра: ${_value(attachments?.viewerFilesBytes)}'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _loading || !_accessible ? null : _measure,
                  child: const Text('Обновить'),
                ),
              ],
            );
          })),
    );
  }
}

class _StorageSection extends StatelessWidget {
  const _StorageSection(
      {required this.icon,
      required this.title,
      required this.children,
      this.color});

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground =
        color == null ? colors.onSurface : colors.onPrimaryContainer;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: color == null ? Border.all(color: colors.outlineVariant) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: DefaultTextStyle.merge(
          style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon,
                  color: color == null ? colors.primary : foreground, size: 22),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(title,
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: foreground, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      ),
    );
  }
}
