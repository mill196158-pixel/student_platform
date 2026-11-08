import 'dart:async';

import 'package:flutter/material.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

/// Partial read-only diagnostics; not an enforced cache quota.
class CacheDiagnosticsScreen extends StatefulWidget {
  const CacheDiagnosticsScreen(
      {super.key,
      this.measure,
      this.budget,
      this.debugCapabilities,
      this.timeout = const Duration(seconds: 5)});
  @visibleForTesting
  final Future<InventorySnapshot> Function()? measure;
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
  int _revision = 0;
  InventorySnapshot? _snapshot;
  int? _budgetObserved;
  int _budgetReserved = 0;
  bool _loading = true;
  bool _changing = false;
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
    final revision = ++_revision;
    if (_historyCapabilities != null) _startHistory();
    setState(() {
      _loading = true;
      _snapshot = null;
      _budgetObserved = null;
    });
    InventorySnapshot? result;
    try {
      final budget = widget.budget ??
          (widget.measure == null ? OptionalImageCacheBudget.instance : null);
      final budgetFuture = budget == null
          ? null
          : Future.wait<void>([
              budget.waitForPolicy(),
              budget.refreshForDisplay(),
            ]);
      result = await (widget.measure?.call() ??
              CacheInventoryCollector.shared.collect())
          .timeout(widget.timeout);
      if (budgetFuture != null) {
        try {
          await budgetFuture.timeout(widget.timeout);
        } catch (_) {}
        if (mounted && revision == _revision) {
          _budgetObserved = budget!.observedBytes;
          _budgetReserved = budget.reservedBytes;
        }
      }
    } catch (_) {
      result = null;
    }
    if (!mounted || revision != _revision) return;
    setState(() {
      _snapshot = result;
      _loading = false;
    });
  }

  String _value(int? bytes) => bytes == null
      ? 'неизвестно'
      : '${(bytes / 1000000).toStringAsFixed(1)} МБ';

  Future<void> _chooseLimit(OptionalImageCacheBudget budget) async {
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
    if (!mounted || choice == null) return;
    setState(() => _changing = true);
    final success = await budget.setLimit(choice);
    if (!mounted) return;
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
    final snapshot = _snapshot;
    final budget = widget.budget ?? OptionalImageCacheBudget.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Данные приложения')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Частичная оценка',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (widget.measure == null || widget.budget != null) ...[
          Text(
              'Учтённые копии новостей и материалов: ${_value(_budgetObserved)}'),
          Text(
              'Резерв активных записей: ${_value(_budgetObserved == null ? null : _budgetReserved)}'),
          Text(budget.policyReady
              ? 'Целевой лимит учтённого серверного кэша — ${_value(budget.limitBytes)}, включая служебный запас ${_value(budget.serviceReserveBytes)}.'
              : 'Целевой лимит учтённого серверного кэша сейчас недоступен.'),
          const Text(
              'Учитываются копии изображений новостей и материалов и часть подтверждённой истории чатов. При превышении лимита старая подтверждённая история может очищаться в фоне при подключении к сети и доступности необходимых проверок. Черновики, неотправленные данные и сохранённые офлайн файлы не входят в эту очистку; остальные данные охвачены не полностью.'),
          OutlinedButton(
              onPressed: _loading || _changing || budget.policyBusy
                  ? null
                  : () => _chooseLimit(budget),
              child: const Text('Изменить целевой лимит')),
          const SizedBox(height: 12),
        ],
        if (_loading)
          const Text('Подсчёт…')
        else if (snapshot == null)
          const Text('Сейчас недоступно')
        else ...[
          for (final item in snapshot.observations)
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${_label(item.name)}: ${_value(item.bytes)}')),
          ValueListenableBuilder<int?>(
              valueListenable: _logicalHistory,
              builder: (_, value, __) => Text(
                  'Логический размер подтверждённой части истории: ${_value(value)}')),
        ],
        const SizedBox(height: 12),
        const Text(
            'Оценки отдельных путей приблизительны и могут включать общие или защищённые данные. Не все хранилища обследованы; одинаковые физические файлы могут быть учтены повторно.'),
        const SizedBox(height: 12),
        const Text(
            'Логический размер истории не равен физическому месту. Это не общий размер и не объём, доступный для очистки. Черновики, неотправленные сообщения и сохранённые офлайн файлы могут учитываться не полностью.'),
        const SizedBox(height: 12),
        const Text(
            'Общий физический лимит приложения и ручная очистка пока недоступны.'),
        const SizedBox(height: 16),
        OutlinedButton(
            onPressed: _loading ? null : _measure,
            child: const Text('Обновить')),
      ]),
    );
  }
}
