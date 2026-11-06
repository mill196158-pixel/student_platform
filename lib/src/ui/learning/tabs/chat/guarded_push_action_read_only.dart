import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';

/// An isolated, non-mutating QA view. The supplied IDs are lookup hints only.
class GuardedPushActionReadOnly extends StatefulWidget {
  const GuardedPushActionReadOnly(
      {super.key,
      required this.client,
      required this.barrier,
      required this.isCurrent,
      required this.kind,
      required this.chatId,
      required this.entityId,
      this.cardMessageId});
  final SupabaseClient client;
  final OnlineSideEffectBarrier barrier;
  final bool Function() isCurrent;
  final String kind, chatId, entityId;
  final String? cardMessageId;
  @override
  State<GuardedPushActionReadOnly> createState() =>
      _GuardedPushActionReadOnlyState();
}

class _GuardedPushActionReadOnlyState extends State<GuardedPushActionReadOnly> {
  final ValueNotifier<bool> _visible = ValueNotifier(true);
  StreamSubscription<AuthState>? _auth;
  late final void Function() _removeClose;
  late final Future<({String title, String description})?> _details;
  bool _current() {
    try {
      return mounted && widget.barrier.isOpen && widget.isCurrent();
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _removeClose = widget.barrier.onClose(() {
      _visible.value = false;
      final sub = _auth;
      _auth = null;
      if (sub != null) unawaited(widget.barrier.trackTeardown(sub.cancel));
    });
    if (_current()) {
      _auth = widget.client.auth.onAuthStateChange.listen((state) {
        if (state.event != AuthChangeEvent.initialSession || !_current()) {
          widget.barrier.close();
        }
      }, onError: (Object _, StackTrace __) {
        widget.barrier.close();
      });
    }
    _details = _load();
  }

  Future<({String title, String description})?> _load() async {
    if (widget.chatId.isEmpty ||
        widget.entityId.isEmpty ||
        (widget.kind != 'topic_selection' && widget.kind != 'group_collection'))
      return null;
    try {
      return await widget.barrier
          .run<({String title, String description})?>(() async {
        if (!_current()) return null;
        final raw = await widget.client.rpc('get_task_details', params: {
          'p_kind': widget.kind,
          'p_entity_id': widget.entityId,
          'p_chat_id': widget.chatId,
        });
        if (!_current() ||
            raw is! Map ||
            raw['available'] != true ||
            raw['kind'] != widget.kind ||
            raw['details_kind'] != widget.kind ||
            raw['entity_id'] != widget.entityId) return null;
        final card = raw['card_message_id'],
            title = raw['title'],
            description = raw['description'];
        if (card is! String ||
            card.trim().isEmpty ||
            (widget.cardMessageId != null && widget.cardMessageId != card) ||
            title is! String ||
            title.trim().isEmpty ||
            title.length > 300 ||
            description is! String ||
            description.length > 4000) return null;
        return _current() ? (title: title, description: description) : null;
      });
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _removeClose();
    final sub = _auth;
    _auth = null;
    if (sub != null) unawaited(widget.barrier.trackTeardown(sub.cancel));
    _visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: _visible,
      builder: (context, visible, _) {
        if (!visible || !_current()) return const SizedBox.shrink();
        return Scaffold(
            appBar: AppBar(title: const Text('Карточка')),
            body: FutureBuilder<({String title, String description})?>(
                future: _details,
                builder: (context, snapshot) {
                  if (!_current()) return const SizedBox.shrink();
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final details = snapshot.data;
                  if (details == null)
                    return const Center(child: Text('Карточка недоступна.'));
                  return ListView(padding: const EdgeInsets.all(20), children: [
                    Text(details.title,
                        style: Theme.of(context).textTheme.titleLarge),
                    if (details.description.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(details.description)
                    ],
                    const SizedBox(height: 20),
                    const Text(
                        'Просмотр без действий. Варианты и вложения здесь недоступны.'),
                  ]);
                }));
      });
}
