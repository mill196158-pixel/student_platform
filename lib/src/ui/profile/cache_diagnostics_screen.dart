import 'dart:async';

import 'package:flutter/material.dart';
import 'package:student_platform/src/core/temporary_cache_budget.dart';

/// Partial, read-only diagnostics; this is not an enforced cache quota.
class CacheDiagnosticsScreen extends StatefulWidget {
  const CacheDiagnosticsScreen(
      {super.key, this.measure, this.timeout = const Duration(seconds: 5)});

  @visibleForTesting
  final Future<int?> Function()? measure;
  @visibleForTesting
  final Duration timeout;

  @override
  State<CacheDiagnosticsScreen> createState() => _CacheDiagnosticsScreenState();
}

class _CacheDiagnosticsScreenState extends State<CacheDiagnosticsScreen> {
  int _revision = 0;
  int? _bytes;
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
      _bytes = null;
    });
    int? result;
    try {
      result = await (widget.measure?.call() ?? TemporaryCacheBudget.measure())
          .timeout(widget.timeout);
      if (result != null && result < 0) result = null;
    } catch (_) {
      result = null;
    }
    if (!mounted || revision != _revision) return;
    setState(() {
      _bytes = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final value = _loading
        ? 'Подсчёт…'
        : _bytes == null
            ? 'Сейчас недоступно'
            : '${(_bytes! / 1000000).toStringAsFixed(1)} МБ';
    return Scaffold(
      appBar: AppBar(title: const Text('Данные приложения')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('Частичная оценка',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text(value, style: const TextStyle(fontSize: 24)),
        const SizedBox(height: 12),
        const Text(
            'Оценка включает временные файлы, физический размер базы истории и её WAL/SHM, а также логический размер части старого кэша сообщений. Она приблизительна, может включать защищённые данные и охватывает не все хранилища приложения.'),
        const SizedBox(height: 12),
        const Text(
            'Это не общий размер и не объём, доступный для очистки. Черновики, неотправленные сообщения и сохранённые офлайн файлы могут учитываться не полностью.'),
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
