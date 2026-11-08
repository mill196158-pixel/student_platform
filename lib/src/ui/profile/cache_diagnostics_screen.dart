import 'dart:async';

import 'package:flutter/material.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';

/// Partial read-only diagnostics; not an enforced cache quota.
class CacheDiagnosticsScreen extends StatefulWidget {
  const CacheDiagnosticsScreen(
      {super.key,
      this.measure,
      this.budget,
      this.timeout = const Duration(seconds: 5)});
  @visibleForTesting
  final Future<InventorySnapshot> Function()? measure;
  @visibleForTesting
  final OptionalImageCacheBudget? budget;
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
  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _snapshot = null;
      _budgetObserved = null;
    });
    InventorySnapshot? result;
    try {
      final budget = widget.budget ??
          (widget.measure == null ? OptionalImageCacheBudget.instance : null);
      final budgetFuture = budget?.refreshForDisplay();
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
          Text(
              'Цель для этих копий — ${_value(budget.limitBytes)}, включая служебный запас ${_value(budget.serviceReserveBytes)}. Остальные кэши и история этим ограничением пока не охвачены.'),
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
          Text(
              'Логический размер истории: ${_value(snapshot.logicalHistoryBytes)}'),
        ],
        const SizedBox(height: 12),
        const Text(
            'Оценки отдельных путей приблизительны и могут включать общие или защищённые данные. Не все хранилища обследованы; одинаковые физические файлы могут быть учтены повторно.'),
        const SizedBox(height: 12),
        const Text(
            'Логический размер истории не равен физическому месту. Это не общий размер и не объём, доступный для очистки. Черновики, неотправленные сообщения и сохранённые офлайн файлы могут учитываться не полностью.'),
        const SizedBox(height: 12),
        const Text('Управление общим лимитом и очистка пока недоступны.'),
        const SizedBox(height: 16),
        OutlinedButton(
            onPressed: _loading ? null : _measure,
            child: const Text('Обновить')),
      ]),
    );
  }
}
