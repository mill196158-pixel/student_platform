import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;

import '../learning/tabs/chat/models/chat_card_envelope.dart';
import 'core/chat_messages_load_state.dart';
import 'data/offline_chat_cache_reader.dart';

/// Local-only presentation. The owning route must revoke and remove this
/// widget immediately when its session admission expires or changes.
class OfflineChatCacheScreen extends StatefulWidget {
  const OfflineChatCacheScreen({
    super.key,
    required this.userId,
    required this.reader,
    required this.onRetryConnection,
  });

  final String userId;
  final OfflineChatCacheReader reader;
  final VoidCallback onRetryConnection;

  @override
  State<OfflineChatCacheScreen> createState() => _OfflineChatCacheScreenState();
}

class _OfflineChatCacheScreenState extends State<OfflineChatCacheScreen> {
  OfflineChatSummary? _selected;
  late Future<OfflineChatList> _list;
  Future<_MessageReadResult>? _messages;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  @override
  void didUpdateWidget(covariant OfflineChatCacheScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.reader != widget.reader) {
      _selected = null;
      _messages = null;
      _loadList();
    }
  }

  void _loadList() => _list = widget.reader.chats(widget.userId);

  void _open(OfflineChatSummary chat) {
    setState(() {
      _selected = chat;
      _messages = _readMessages(widget.reader, widget.userId, chat.id);
    });
  }

  Future<_MessageReadResult> _readMessages(
      OfflineChatCacheReader reader, String userId, String chatId) async {
    try {
      return _MessageReadResult(await reader.messages(userId, chatId));
    } catch (_) {
      return const _MessageReadResult(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(
        leading: selected == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _selected = null;
                  _messages = null;
                }),
              ),
        title: Text(selected?.title ?? 'Сохранённые чаты'),
      ),
      body: Column(children: [
        MaterialBanner(
          content:
              const Text('Нет сети. Доступен только просмотр сохранённого.'),
          actions: [
            TextButton(
                onPressed: widget.onRetryConnection,
                child: const Text('Повторить')),
          ],
        ),
        Expanded(
          child: selected == null
              ? FutureBuilder<OfflineChatList>(
                  key: ValueKey(_list),
                  future: _list,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const _Notice('Не удалось прочитать кэш.');
                    }
                    if (!snapshot.hasData) {
                      return const Center(
                          child: ProductLoadingIndicator(size: 160));
                    }
                    final result = snapshot.data!;
                    if (result.state == OfflineChatListState.missing) {
                      return const _Notice('Список чатов ещё не сохранён.');
                    }
                    if (result.state == OfflineChatListState.corrupt) {
                      return const _Notice(
                          'Не удалось прочитать сохранённый список.');
                    }
                    if (result.chats.isEmpty && !result.partiallyDamaged) {
                      return const _Notice('В сохранённом списке нет чатов.');
                    }
                    return ListView(children: [
                      if (result.partiallyDamaged)
                        const ListTile(
                            title: Text('Часть списка не удалось прочитать.')),
                      for (final chat in result.chats)
                        ListTile(
                          leading: const CircleAvatar(
                              child: Icon(Icons.chat_bubble_outline)),
                          title: Text(chat.title),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(chat),
                        ),
                    ]);
                  },
                )
              : FutureBuilder<_MessageReadResult>(
                  key: ValueKey(_messages),
                  future: _messages,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const _Notice('Не удалось прочитать сообщения.');
                    }
                    if (!snapshot.hasData) {
                      return const Center(
                          child: ProductLoadingIndicator(size: 160));
                    }
                    final cached = snapshot.data!.snapshot;
                    if (cached == null) {
                      return const _Notice('Не удалось прочитать сообщения.');
                    }
                    if (!cached.found) {
                      return const _Notice(
                          'Сообщения этого чата ещё не сохранены.');
                    }
                    final messages = cached.messages
                        .where((m) =>
                            cached.clearedAt == null ||
                            m.at.isAfter(cached.clearedAt!))
                        .toList();
                    return ListView(children: [
                      ListTile(
                        title: Text(cached.lastSyncedAt == null
                            ? 'Время синхронизации неизвестно'
                            : 'Обновлено: ${DateFormat('dd.MM.yyyy HH:mm').format(cached.lastSyncedAt!.toLocal())}'),
                        subtitle: Text(cached.hasMoreBefore
                            ? 'Показана часть сохранённой истории.'
                            : 'Показаны сохранённые сообщения.'),
                      ),
                      if (messages.isEmpty)
                        const ListTile(
                            title: Text('Сохранённых сообщений нет.')),
                      for (final message in messages)
                        ListTile(
                          title: Text(message.authorName),
                          subtitle: Text([
                            if (ChatCardPreview.forPreview(message)
                                .trim()
                                .isNotEmpty)
                              ChatCardPreview.forPreview(message),
                            if ((message.attachments?.isNotEmpty ?? false) ||
                                message.fileId != null ||
                                message.imagePath != null)
                              'Вложение',
                            if (message.isSending) 'Не отправлено',
                            if (message.isFailed) 'Не удалось отправить',
                          ].join('\n')),
                        ),
                    ]);
                  },
                ),
        ),
      ]),
    );
  }
}

class _MessageReadResult {
  const _MessageReadResult(this.snapshot);
  final ChatCacheSnapshot? snapshot;
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
