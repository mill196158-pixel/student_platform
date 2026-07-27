import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/admin_backend_config.dart';
import '../../core/auth/admin_session_controller.dart';

class ModerationScreen extends StatefulWidget {
  const ModerationScreen({super.key, required this.session});
  final AdminSessionController session;
  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String _flags = 'structured=on, text=off';
  String _statusFilter = 'queue';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (AdminBackendConfig.isDemoMode) {
        _items = [
          {
            'review_id': 'demo-1',
            'entity_type': 'teacher',
            'status': 'active',
            'open_reports': 2,
            'has_text': false,
            'tag_scores': {'clarity': 4},
          },
        ];
        _flags = 'structured=on, text=off (feature flag)';
      } else {
        final client = Supabase.instance.client;
        final flags = await client.rpc('get_review_feature_flags');
        final decodedFlags = flags is String ? jsonDecode(flags) : flags;
        final map = Map<String, dynamic>.from(decodedFlags as Map? ?? {});
        _flags =
            'structured=${map['reviews.structured_enabled'] == true}, text=${map['reviews.text_enabled'] == true}';
        final queue = await client.rpc(
          'admin_list_moderation_queue',
          params: {'p_status': _statusFilter},
        );
        final decoded = queue is String ? jsonDecode(queue) : queue;
        _items = (decoded as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _moderate(String reviewId, String action) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action == 'hide' ? 'Скрыть отзыв' : 'Восстановить отзыв'),
        content: TextField(
          controller: reason,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Причина решения (обязательно)',
            helperText:
                'Автор не публикуется. Текст причины сохраняется в журнале модерации.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (reason.text.trim().isEmpty) return;
              Navigator.pop(context, true);
            },
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!AdminBackendConfig.isDemoMode) {
      await Supabase.instance.client.rpc(
        'admin_moderate_review',
        params: {
          'p_review_id': reviewId,
          'p_action': action,
          'p_reason_text': reason.text.trim(),
        },
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        widget.session.isLocalPrototype ||
        widget.session.capabilities.can('moderation.write');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Модерация отзывов',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          'Очередь жалоб. Авторы не раскрываются публично. Flags: $_flags. '
          'Голосование сложности предметов/преподавателей не затрагивается.',
        ),
        const SizedBox(height: 12),
        DropdownButton<String>(
          value: _statusFilter,
          items: const [
            DropdownMenuItem(value: 'queue', child: Text('Очередь жалоб')),
            DropdownMenuItem(value: 'hidden', child: Text('Скрытые')),
            DropdownMenuItem(value: 'all', child: Text('Все')),
          ],
          onChanged: (value) {
            _statusFilter = value ?? 'queue';
            _load();
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Card(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? const Center(child: Text('Очередь пуста'))
                : ListView(
                    children: [
                      for (final item in _items)
                        ListTile(
                          title: Text(
                            '${item['entity_type']} · reports=${item['open_reports']}',
                          ),
                          subtitle: Text(
                            'tags=${item['tag_scores']}\n'
                            'text=${item['body_text'] ?? '—'}\n'
                            'reports=${item['reports'] ?? item['open_reports']}',
                          ),
                          isThreeLine: true,
                          trailing: canWrite
                              ? Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton(
                                      onPressed: () async {
                                        if (!AdminBackendConfig.isDemoMode) {
                                          final actions = await Supabase
                                              .instance
                                              .client
                                              .rpc(
                                                'admin_list_moderation_actions',
                                                params: {
                                                  'p_review_id':
                                                      item['review_id'],
                                                },
                                              );
                                          if (!context.mounted) return;
                                          await showDialog<void>(
                                            context: context,
                                            builder: (context) => AlertDialog(
                                              title: const Text('Журнал'),
                                              content: Text('$actions'),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(context),
                                                  child: const Text('Закрыть'),
                                                ),
                                              ],
                                            ),
                                          );
                                        }
                                      },
                                      child: const Text('Журнал'),
                                    ),
                                    TextButton(
                                      onPressed: () => _moderate(
                                        '${item['review_id']}',
                                        'hide',
                                      ),
                                      child: const Text('Скрыть'),
                                    ),
                                    TextButton(
                                      onPressed: () => _moderate(
                                        '${item['review_id']}',
                                        'restore',
                                      ),
                                      child: const Text('Восстановить'),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
