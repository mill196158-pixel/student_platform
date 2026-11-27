import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';

class CacheDiagnosticsScreen extends StatefulWidget {
  const CacheDiagnosticsScreen({
    super.key,
    this.measure,
    this.clearNews,
    this.canAccess,
    this.timeout = const Duration(seconds: 5),
  });

  @visibleForTesting
  final Future<InventorySnapshot> Function()? measure;
  @visibleForTesting
  final Future<PublicNewsClearResult> Function()? clearNews;

  /// Rechecks the original offline route permit before dispatching an action.
  final bool Function()? canAccess;
  @visibleForTesting
  final Duration timeout;

  @override
  State<CacheDiagnosticsScreen> createState() => _CacheDiagnosticsScreenState();
}

class _CacheDiagnosticsScreenState extends State<CacheDiagnosticsScreen>
    with WidgetsBindingObserver {
  bool get _accessible => mounted && (widget.canAccess?.call() ?? true);
  int _revision = 0;
  int? _bytes;
  bool _clearPending = false;
  String? _clearMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_measure());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_clearPending) {
      unawaited(_measure());
    }
  }

  Future<void> _measure() async {
    if (!_accessible) return;
    final revision = ++_revision;
    int? bytes;
    try {
      final read = widget.measure ?? CacheInventoryCollector.shared.collect;
      final snapshot = await read().timeout(widget.timeout);
      // This is the space used by the replaceable image copies the action
      // can remove. Protected histories, drafts and saved files are separate.
      for (final item in snapshot.observations) {
        if (item.name == 'public_news_blobs_v2' &&
            item.classification == InventoryClass.optional) {
          bytes = item.bytes;
          break;
        }
      }
    } catch (_) {
      // Leave an unverified measurement out of the screen.
    }
    if (_accessible && revision == _revision) {
      setState(() => _bytes = bytes);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1000) return '$bytes Б';
    if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} кБ';
    return '${(bytes / 1000000).toStringAsFixed(1)} МБ';
  }

  Future<void> _confirmClear() async {
    if (_clearPending || !_accessible) return;
    setState(() => _clearPending = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Очистить кэш?'),
          content: const Text(
            'Приложение удалит временные копии. Переписка и сохранённые офлайн-файлы останутся.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Очистить'),
            ),
          ],
        ),
      );
      if (confirmed != true || !_accessible) return;
      setState(() => _clearMessage = 'Очищаем кэш…');
      final clear =
          widget.clearNews ?? PublicNewsImageCache.shared.clearStoredCopies;
      final result = await clear();
      if (!_accessible) return;
      setState(() => _clearMessage = switch (result.status) {
            PublicNewsClearStatus.complete => 'Кэш очищен.',
            PublicNewsClearStatus.partial =>
              'Часть временных файлов осталась. Можно повторить очистку.',
            PublicNewsClearStatus.unavailable =>
              'Не удалось очистить кэш. Попробуйте ещё раз.',
          });
      await _measure();
    } catch (_) {
      if (_accessible) {
        setState(() =>
            _clearMessage = 'Не удалось очистить кэш. Попробуйте ещё раз.');
      }
    } finally {
      if (mounted) setState(() => _clearPending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = colors.surfaceContainerLow;
    final titleHeight = MediaQuery.textScalerOf(context).scale(18) * 2.4;
    final bytes = _accessible ? _bytes : null;
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leadingWidth: 52,
        titleSpacing: 6,
        toolbarHeight: math.max(kToolbarHeight, titleHeight + 12),
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: 'Назад',
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : const SizedBox.shrink(),
        actions: const [SizedBox(width: 52)],
        title: Text(
          'Данные приложения',
          textAlign: TextAlign.center,
          maxLines: 2,
          style: theme.textTheme.titleMedium?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: colors.onSurface,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Кэш',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (bytes != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            _formatSize(bytes),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: colors.onSurface,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          'Временные изображения удалятся. При необходимости они загрузятся снова.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: _clearPending || !_accessible
                              ? null
                              : _confirmClear,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                          child: const Text(
                            'Очистить кэш',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (_clearMessage case final message?) ...[
                          const SizedBox(height: 8),
                          Semantics(liveRegion: true, child: Text(message)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
