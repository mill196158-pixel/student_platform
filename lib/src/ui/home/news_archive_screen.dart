import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_dashboard_service.dart';
import 'models/home_dashboard_data.dart';

class NewsArchiveScreen extends StatefulWidget {
  const NewsArchiveScreen({super.key, required this.load, required this.open});

  final Future<PublishedNewsPage> Function(Map<String, dynamic>? cursor) load;
  final ValueChanged<HomeNewsItem> open;

  @override
  State<NewsArchiveScreen> createState() => _NewsArchiveScreenState();
}

class _NewsArchiveScreenState extends State<NewsArchiveScreen> {
  List<HomeNewsItem> _items = [];
  Map<String, dynamic>? _next;
  int _pages = 0;
  int _request = 0;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(refresh: true));
  }

  Future<void> _load({required bool refresh}) async {
    if (!refresh && (_busy || _next == null)) return;
    final request = ++_request;
    final boundary = refresh ? _items.lastOrNull?.id : null;
    final previousDepth = _pages;
    final byId = {
      if (!refresh)
        for (final item in _items) item.id: item
    };
    var cursor = refresh ? null : _next;
    var pages = refresh ? 0 : previousDepth;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      do {
        final page = await widget.load(cursor);
        if (!mounted || request != _request) return;
        for (final item in page.items) {
          byId[item.id] = item;
        }
        cursor = page.next;
        pages++;
        // Keep the previously read boundary if a new entry displaced it onto
        // the following page. A deleted boundary must not trigger an unlimited scan.
      } while (refresh &&
          cursor != null &&
          boundary != null &&
          !byId.containsKey(boundary) &&
          pages <= previousDepth);
      setState(() {
        _items = byId.values.toList();
        _next = cursor;
        _pages = pages;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      final denied = error is PostgrestException &&
          {'42501', '28000', 'PGRST301', 'PGRST303'}.contains(error.code);
      setState(() {
        _failed = true;
        if (refresh || denied) {
          _items = [];
          _next = null;
          _pages = 0;
        }
      });
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Новости'), actions: [
        IconButton(
          tooltip: 'Обновить новости',
          onPressed: _busy ? null : () => _load(refresh: true),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ]),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _load(refresh: true),
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _items.length + 1,
            itemBuilder: (context, index) {
              if (index == _items.length) {
                if (_busy) {
                  return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()));
                }
                if (_failed)
                  return Column(children: [
                    const Text('Не удалось загрузить новости.'),
                    TextButton(
                        onPressed: () => _load(refresh: _next == null),
                        child: const Text('Повторить')),
                  ]);
                if (_next != null)
                  return Center(
                      child: TextButton(
                          onPressed: () => _load(refresh: false),
                          child: const Text('Показать ещё')));
                if (_items.isEmpty)
                  return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('Пока нет новостей')));
                return const SizedBox(height: 16);
              }
              final item = _items[index];
              final text =
                  item.subtitle.trim().isEmpty ? item.body : item.subtitle;
              return ListTile(
                key: ValueKey('news-row-${item.id}'),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          MaterialLocalizations.of(context).formatMediumDate(
                              (item.publishedAt ?? item.createdAt).toLocal()),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                      const SizedBox(height: 3),
                      Text(item.title.trim().isEmpty ? 'Новость' : item.title),
                    ]),
                subtitle: text.trim().isEmpty
                    ? null
                    : Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Icon(Icons.chevron_right_rounded,
                    color: colors.onSurfaceVariant),
                onTap: () => widget.open(item),
              );
            },
          ),
        ),
      ),
    );
  }
}
