import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/online_side_effect_barrier.dart';
import '../learning/models/message.dart';
import '../learning/tabs/chat/message_bubble.dart';
import '../learning/tabs/chat/models/chat_card_envelope.dart';
import 'data/dm_api.dart';
import 'core/forward_payload.dart';

/// Restricted QA preview; it never starts the ordinary chat's side effects.
class GuardedPushDmReadOnly extends StatefulWidget {
  const GuardedPushDmReadOnly(
      {super.key,
      required this.client,
      required this.userId,
      required this.chatId,
      required this.barrier,
      required this.isCurrent,
      this.title = 'Личный чат'});
  final SupabaseClient client;
  final String userId, chatId;
  final OnlineSideEffectBarrier barrier;
  final bool Function() isCurrent;
  final String title;
  @override
  State<GuardedPushDmReadOnly> createState() => _GuardedPushDmReadOnlyState();
}

class _GuardedPushDmReadOnlyState extends State<GuardedPushDmReadOnly> {
  final ValueNotifier<bool> _visible = ValueNotifier(true);
  StreamSubscription<AuthState>? _auth;
  late final void Function() _removeClose;
  late final Future<ConfirmedDmPage?> _page;
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
    _page = _load();
  }

  bool _isForwardEnvelope(String text) {
    if (!text.startsWith('__FG__:')) return false;
    try {
      final value = jsonDecode(text.substring('__FG__:'.length));
      if (value is! Map || value['fg'] != 1 || value['items'] is! List) {
        return false;
      }
      final source = value['from'] ?? value['from_chat_id'];
      final items = value['items'] as List;
      if (source is! String ||
          source.trim().isEmpty ||
          items.isEmpty ||
          items.any((item) {
            if (item is! Map) return true;
            final id = item['id'] ?? item['mid'];
            return id is! String || id.trim().isEmpty;
          })) return false;
      final forward = ForwardPayload.tryParse(text);
      return forward != null && forward.items.length == items.length;
    } catch (_) {
      return false;
    }
  }

  Future<ConfirmedDmPage?> _load() async {
    try {
      return await widget.barrier.run<ConfirmedDmPage?>(() async {
        if (!_current()) return null;
        final raw = await widget.client.rpc('get_chat_messages_page', params: {
          'p_chat_id': widget.chatId,
          'p_limit': 50,
        });
        if (!_current()) return null;
        if (raw is! List || raw.length > 50)
          throw const FormatException('Invalid page size');
        final page =
            DmApi.parseConfirmedMessagesPage(raw, widget.chatId, limit: 50);
        return _current() ? page : null;
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
            appBar: AppBar(title: Text(widget.title)),
            body: Column(children: [
              const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                      'Просмотр сообщений. Отправка и вложения здесь недоступны.')),
              Expanded(
                  child: FutureBuilder<ConfirmedDmPage?>(
                      future: _page,
                      builder: (context, snapshot) {
                        if (!_current()) return const SizedBox.shrink();
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        final page = snapshot.data;
                        if (page == null)
                          return const Center(
                              child: Text('Сообщения недоступны.'));
                        final messages = page.messages
                            .where((m) =>
                                (m.cardKind?.trim().isEmpty ?? true) &&
                                !ChatCardPreview.looksLikeCardJson(m.text) &&
                                m.type == MessageType.text &&
                                !_isForwardEnvelope(m.text))
                            .toList();
                        return Column(children: [
                          if (page.hasMore)
                            const Padding(
                              padding: EdgeInsets.all(8),
                              child: Text(
                                  'Показаны последние сообщения; более ранние здесь недоступны.'),
                            ),
                          Expanded(
                              child: messages.isEmpty
                                  ? Center(
                                      child: Text(page.messages.isEmpty
                                          ? 'Сообщений пока нет'
                                          : 'Некоторые сообщения недоступны в этом просмотре.'))
                                  : ListView.builder(
                                      itemCount: messages.length,
                                      itemBuilder: (context, index) {
                                        final m = messages[index];
                                        return MessageBubble(
                                            message: m,
                                            time: DateFormat('HH:mm')
                                                .format(m.at.toLocal()),
                                            showAvatar: false,
                                            reserveAvatarSpace: false,
                                            showAuthorLine: false,
                                            localOnlyUserId: widget.userId,
                                            receiptTicks: 0);
                                      }))
                        ]);
                      }))
            ]));
      });
}
