import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services;
import 'package:flutter_chat_reactions/flutter_chat_reactions.dart' as fcr;
import '../../../models/message.dart';
import '../date_separator.dart';
import '../swipe_to_reply.dart';
import '../search/chat_search_controller.dart';
import '../search/search_highlight.dart';
import '../message_builder.dart';
import '../message_receipt.dart';

class ChatMessageList extends StatelessWidget {
  final List<Message> messages;
  final ScrollController controller;
  final Map<String, GlobalKey> messageKeys;
  final Map<String, GlobalKey>? boundaryKeys;
  final ChatSearchController search;
  final String? currentUserId;
  // ⬅️ НОВОЕ: момент «видел до» на входе для вставки разделителя
  final DateTime? entrySeenAt;
  // Показывать ли чип «Новые сообщения» в эту сессию
  final bool showEntryNewBadge;
  // Принудительно скрывать аватарки (для ЛС)
  final bool forceHideAvatars;
  // DM: убирать зазор под аватар
  final bool noAvatarSpacing;
  // DM: скрывать строку автора
  final bool hideAuthorLine;
  // NEW: полностью скрыть идентификаторы отправителей (аватар/инициалы/имя)
  final bool hideSenderIdentity;
  // DM-only: one/two checkmarks from peer chat_reads.last_read_at
  final bool enableDmReceipts;
  final DateTime? peerLastReadAt;
  // Временная подсветка сообщения при открытом меню действий
  final String? hoveredMessageId;

  final void Function(Message m) onReply;
  final void Function(
      BuildContext ctx,
      Message m,
      Rect? targetRect,
      Uint8List? bubbleBytes,
      String? replyPreview,
      Offset? fallbackPosition) onLongPress;
  final void Function(String replyId) onReplyTap;
  final void Function(BuildContext ctx, String messageId) onReact;
  final void Function(String messageId, String emoji)? onReactionSelected;
  final void Function(Message m, String action)? onMenuAction;
  final bool Function(Message m)? canDeleteMessage;
  final bool Function(Message m)? canEditMessage;
  final bool selectingMessages;
  final Set<String>? selectedMessageIds;
  final void Function(String id)? onToggleSelect;
  final void Function(Message m)? onRetryFailedText;
  final VoidCallback? onFocusComposer;
  final VoidCallback? onAttachFile;
  final VoidCallback? onCreateAssignment;
  /// When true, empty-state copy is DM-oriented (no team assignment CTAs).
  final bool isDirectChat;
  final bool initialLoading;
  final bool loadError;
  final VoidCallback? onRetryLoad;

  /// Authors blocked by the current user (group/team only). One set for the screen.
  final Set<String>? blockedUserIds;

  /// Locally revealed blocked-message ids for this screen session.
  final Set<String>? revealedBlockedMessageIds;
  final void Function(String messageId)? onRevealBlockedMessage;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.controller,
    required this.messageKeys,
    this.boundaryKeys,
    required this.search,
    required this.currentUserId,
    this.entrySeenAt,
    this.showEntryNewBadge = true,
    this.forceHideAvatars = false,
    this.noAvatarSpacing = false,
    this.hideAuthorLine = false,
    this.hideSenderIdentity = false,
    this.enableDmReceipts = false,
    this.peerLastReadAt,
    this.hoveredMessageId,
    required this.onReply,
    required this.onLongPress,
    required this.onReplyTap,
    required this.onReact,
    this.onReactionSelected,
    this.onMenuAction,
    this.canDeleteMessage,
    this.canEditMessage,
    required this.selectingMessages,
    required this.selectedMessageIds,
    required this.onToggleSelect,
    this.onRetryFailedText,
    this.onFocusComposer,
    this.onAttachFile,
    this.onCreateAssignment,
    this.isDirectChat = false,
    this.initialLoading = false,
    this.loadError = false,
    this.onRetryLoad,
    this.blockedUserIds,
    this.revealedBlockedMessageIds,
    this.onRevealBlockedMessage,
  });

  @override
  Widget build(BuildContext context) {
    // старые сверху → новые снизу
    final list = [...messages]..sort((a, b) => a.at.compareTo(b.at));

    if (list.isEmpty && initialLoading) {
      return const _InitialChatLoadingState();
    }

    if (list.isEmpty && loadError) {
      return _ChatLoadErrorState(onRetry: onRetryLoad);
    }

    if (list.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final height =
              constraints.maxHeight.isFinite ? constraints.maxHeight : 320.0;
          return ListView(
            controller: controller,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(24, 96.0, 24, 12),
            children: [
              SizedBox(
                height: height > 140 ? height - 108 : 180,
                child: _EmptyChatState(
                  isDirectChat: isDirectChat,
                  onFocusComposer: onFocusComposer,
                  onAttachFile: onAttachFile,
                  onCreateAssignment: isDirectChat ? null : onCreateAssignment,
                ),
              ),
            ],
          );
        },
      );
    }

    // Перестраиваем список при изменении поиска, чтобы корректно подсвечивать и скроллить к результатам
    return AnimatedBuilder(
      animation: search,
      builder: (context, _) {
        return ListView.builder(
          controller: controller,
          reverse: true,
          // reverse:true инвертирует направление; чтобы «зазор под композером» был снизу экрана,
          // используем верхний паддинг. Так одиночное первое сообщение начинается «сверху» без лишнего отступа.
          padding: const EdgeInsets.fromLTRB(12, 96.0, 12, 12),
          // Большая cacheExtent помогает обеспечить наличие RenderObject для ensureVisible
          cacheExtent: 100000,
          itemCount: list.length,
          itemBuilder: (ctx, i) {
            // reverse:true → берём элемент с конца
            final idx = list.length - 1 - i;
            final m = list[idx];

            // Marker key for scrolling only. Do not wrap the whole message subtree
            // with a GlobalKey: assignment bubbles depend on inherited providers,
            // and moving global-keyed subtrees can trip Flutter's deactivation assert.
            final key = messageKeys.putIfAbsent(m.id, () => GlobalKey());

            // Определяем, нужен ли разделитель даты (сравниваем с предыдущим по времени сообщением)
            final bool isNewDay =
                idx == 0 || !_isSameDay(list[idx - 1].at, m.at);

            // reply preview (покажем имя файла, если отвечаем на файл)
            final reply = m.replyToId != null
                ? messages.firstWhere(
                    (x) => x.id == m.replyToId,
                    orElse: () => Message(
                      id: '0',
                      chatId: '',
                      authorId: '',
                      authorLogin: '',
                      authorName: '',
                      text: '',
                      at: DateTime.now(),
                    ),
                  )
                : null;
            String? replyPreviewText;
            if (reply != null && reply.id != '0') {
              if (_isBlockedAuthorContentHidden(reply)) {
                replyPreviewText = 'Сообщение заблокированного пользователя';
              } else {
                final t = (reply.text).toString().trim();
                if (t.isNotEmpty) {
                  replyPreviewText = t;
                } else {
                  final atts = reply.attachments ?? const [];
                  if (atts.isNotEmpty) {
                    final firstName = (atts.first.fileName).toString();
                    if (atts.length == 1) {
                      replyPreviewText =
                          firstName.isNotEmpty ? firstName : 'Вложение';
                    } else {
                      replyPreviewText =
                          '${firstName.isNotEmpty ? firstName : 'Вложения'} +${atts.length - 1}';
                    }
                  }
                }
              }
            }

            final collapseBlocked = _shouldCollapseBlockedMessage(m);

            final currentReactions = m.reactions ?? const <String, int>{};
            final hasReactions = currentReactions.isNotEmpty;

            final isMine = m.isMine(currentUserId);
            final shouldShowSender = isMine
                ? false
                : hideSenderIdentity
                    ? false
                    : (forceHideAvatars ? false : _shouldShowAvatar(list, idx));
            final reserveAvatarSpaceForChip =
                !isMine && !hideSenderIdentity && !noAvatarSpacing;
            final isGroupedWithPrevious =
                idx > 0 && !_shouldShowAvatar(list, idx);

            final receiptTicks = dmReceiptTicks(
              isMine: isMine,
              enableDmReceipts: enableDmReceipts,
              messageAt: m.at,
              peerLastReadAt: peerLastReadAt,
              isSending: m.isSending,
              isFailed: m.isFailed,
            );

            final bubble = buildBubble(
              m: m,
              // скрыть любые идентификаторы отправителей, если требуется (превью ЛС)
              showAvatar: shouldShowSender,
              // без слотов под аватар, когда прячем идентичность
              reserveAvatarSpace:
                  hideSenderIdentity || isMine ? false : !noAvatarSpacing,
              // строку автора тоже прячем, если hideSenderIdentity=true
              showAuthorLine: hideSenderIdentity
                  ? false
                  : (!hideAuthorLine && shouldShowSender),
              time: _time(m.at),
              onLongPress: null,
              onReply: () => onReply(m),
              onReplyTap: onReplyTap,
              replyPreview: replyPreviewText,
              authorAvatarUrl: m.authorAvatarUrl,
              authorName: m.authorName,
              attachments: m.attachments,
              isMe: isMine,
              caption: m.text,
              reactions: const <String, Map<String, int>>{},
              onReact: () => onReact(ctx, m.id),
              onRetryFailed:
                  m.isFailed ? () => onRetryFailedText?.call(m) : null,
              selected: ((selectingMessages &&
                      (selectedMessageIds?.contains(m.id) ?? false)) ||
                  hoveredMessageId == m.id),
              boundaryKey: null,
              receiptTicks: receiptTicks,
            );

            final previewBubble = buildBubble(
              m: m,
              showAvatar: shouldShowSender,
              reserveAvatarSpace:
                  hideSenderIdentity || isMine ? false : !noAvatarSpacing,
              showAuthorLine: hideSenderIdentity
                  ? false
                  : (!hideAuthorLine && shouldShowSender),
              time: _time(m.at),
              onLongPress: null,
              onReply: () => onReply(m),
              onReplyTap: onReplyTap,
              replyPreview: replyPreviewText,
              authorAvatarUrl: m.authorAvatarUrl,
              authorName: m.authorName,
              attachments: m.attachments,
              isMe: isMine,
              caption: m.text,
              reactions: const <String, Map<String, int>>{},
              onReact: () => onReact(ctx, m.id),
              onRetryFailed:
                  m.isFailed ? () => onRetryFailedText?.call(m) : null,
              selected: true,
              boundaryKey: null,
              receiptTicks: receiptTicks,
            );

            final bubbleWithKey = bubble;

            // Вставляем "Новые сообщения" один раз перед первым сообщением строго ПОЗЖЕ границы (UTC-нормализация)
            final boundaryUtc = entrySeenAt?.toUtc();
            final currIsNew =
                boundaryUtc != null && m.at.toUtc().isAfter(boundaryUtc);
            final prevIsNew = boundaryUtc != null &&
                idx > 0 &&
                list[idx - 1].at.toUtc().isAfter(boundaryUtc);
            final bool shouldInsertNewDivider = showEntryNewBadge &&
                boundaryUtc != null &&
                currIsNew &&
                !prevIsNew;

            final children = <Widget>[];

            if (isNewDay) {
              children.add(
                DateSeparator(
                    key:
                        ValueKey('date-${m.at.year}-${m.at.month}-${m.at.day}'),
                    date: m.at),
              );
            }

            if (shouldInsertNewDivider) {
              // debug: log insertion point
              assert(() {
                debugPrint(
                    '[DIVIDER] before msg ${m.id} at ${m.at.toUtc()} boundary=$boundaryUtc');
                return true;
              }());
              children.add(const _NewMessagesChip());
            }

            children.add(
              KeyedSubtree(
                key: ValueKey('message-${m.id}'),
                child: Column(
                  children: [
                    SizedBox(key: key, height: 0),
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: collapseBlocked
                            ? 5
                            : (hasReactions
                                ? 18
                                : (isGroupedWithPrevious ? 1 : 5)),
                      ),
                      child: collapseBlocked
                          ? _BlockedAuthorMessagePlaceholder(
                              onShow: () => onRevealBlockedMessage?.call(m.id),
                            )
                          : SwipeToReply(
                              onReply: () => onReply(m),
                              child: SearchHighlight(
                                active: search.isActive,
                                isCurrent: m.id == search.currentTargetId,
                                onTap: () {
                                  final key = messageKeys[m.id];
                                  if (key?.currentContext != null) {
                                    try {
                                      Scrollable.ensureVisible(
                                        key!.currentContext!,
                                        duration:
                                            const Duration(milliseconds: 240),
                                        alignment: 0.12,
                                        curve: Curves.easeOutCubic,
                                      );
                                    } catch (_) {}
                                  }
                                },
                                child: _ChatMessageInteractionWrapper(
                                  message: m,
                                  isMine: isMine,
                                  currentUserId: currentUserId,
                                  selectingMessages: selectingMessages,
                                  isSelected:
                                      selectedMessageIds?.contains(m.id) ??
                                          false,
                                  isHovered: hoveredMessageId == m.id,
                                  reactions: currentReactions,
                                  canDelete: canDeleteMessage?.call(m) ?? false,
                                  canEdit: canEditMessage?.call(m) ?? false,
                                  reactionLeft: isMine
                                      ? null
                                      : (hideSenderIdentity ||
                                              noAvatarSpacing ||
                                              !reserveAvatarSpaceForChip
                                          ? 12
                                          : 52),
                                  reactionRight: isMine ? 12 : null,
                                  onToggleSelect: () =>
                                      onToggleSelect?.call(m.id),
                                  onReact: () => onReact(ctx, m.id),
                                  onReactionSelected: (emoji) {
                                    final handler = onReactionSelected;
                                    if (handler != null) {
                                      handler(m.id, emoji);
                                    } else {
                                      onReact(ctx, m.id);
                                    }
                                  },
                                  onMenuAction: (action) =>
                                      onMenuAction?.call(m, action),
                                  child: bubbleWithKey,
                                  previewChild: previewBubble,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            );
          },
        );
      },
    );
  }

  String _time(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isNeverCollapsedType(Message m) {
    if (m.isSystem) return true;
    if (m.type == MessageType.assignmentDraft ||
        m.type == MessageType.assignmentPublished) {
      return true;
    }
    if ((m.assignmentId ?? '').isNotEmpty) return true;
    return false;
  }

  bool _isBlockedAuthor(Message m) {
    final blocked = blockedUserIds;
    if (blocked == null || blocked.isEmpty) return false;
    final authorId = m.authorId.trim();
    if (authorId.isEmpty) return false;
    return blocked.contains(authorId);
  }

  bool _isBlockedAuthorContentHidden(Message m) {
    if (_isNeverCollapsedType(m)) return false;
    if (!_isBlockedAuthor(m)) return false;
    final revealed = revealedBlockedMessageIds;
    if (revealed != null && revealed.contains(m.id)) return false;
    return true;
  }

  bool _shouldCollapseBlockedMessage(Message m) {
    return _isBlockedAuthorContentHidden(m);
  }

  bool _shouldShowAvatar(List<Message> messages, int currentIndex) {
    if (currentIndex == 0) return true;
    final currentMessage = messages[currentIndex];
    final previousMessage = messages[currentIndex - 1];
    if (currentMessage.authorId != previousMessage.authorId) return true;
    final timeDiff = currentMessage.at.difference(previousMessage.at);
    if (timeDiff.inMinutes > 5) return true;
    if (currentMessage.isSystem) return true;
    if (currentMessage.type == MessageType.assignmentDraft ||
        currentMessage.type == MessageType.assignmentPublished) return true;
    if (currentMessage.type == MessageType.file) return true;
    return false;
  }
}

class _InitialChatLoadingState extends StatelessWidget {
  const _InitialChatLoadingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView.separated(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 96, 16, 12),
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final isMe = index.isEven;
        final width = index.isEven ? 180.0 : 240.0;
        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: width,
            height: index == 0 ? 58 : 44,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .35),
              ),
            ),
            child: index == 0
                ? Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _ChatMessageInteractionWrapper extends StatelessWidget {
  final Message message;
  final bool isMine;
  final String? currentUserId;
  final bool selectingMessages;
  final bool isSelected;
  final bool isHovered;
  final Map<String, int> reactions;
  final bool canDelete;
  final bool canEdit;
  final double? reactionLeft;
  final double? reactionRight;
  final VoidCallback onToggleSelect;
  final VoidCallback onReact;
  final void Function(String emoji) onReactionSelected;
  final void Function(String action)? onMenuAction;
  final Widget child;
  final Widget previewChild;

  const _ChatMessageInteractionWrapper({
    required this.message,
    required this.isMine,
    required this.currentUserId,
    required this.selectingMessages,
    required this.isSelected,
    required this.isHovered,
    required this.reactions,
    required this.canDelete,
    required this.canEdit,
    required this.reactionLeft,
    required this.reactionRight,
    required this.onToggleSelect,
    required this.onReact,
    required this.onReactionSelected,
    required this.onMenuAction,
    required this.child,
    required this.previewChild,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final applyHighlight = (selectingMessages && isSelected) || isHovered;
    final hasReactions = reactions.isNotEmpty;
    final controller = _buildPackageController();
    ValueNotifier<Offset?>? dragPosition;
    ValueNotifier<int>? dragRelease;
    PointerRoute? dragPointerRoute;
    int? dragPointer;
    var dragDisposed = true;
    var dragReleased = false;

    void detachPointerRoute() {
      final route = dragPointerRoute;
      final pointer = dragPointer;
      if (route != null && pointer != null) {
        GestureBinding.instance.pointerRouter.removeRoute(pointer, route);
      }
      dragPointerRoute = null;
      dragPointer = null;
    }

    void ensureDragNotifiers() {
      if (!dragDisposed) return;
      dragPosition = ValueNotifier<Offset?>(null);
      dragRelease = ValueNotifier<int>(0);
      dragDisposed = false;
      dragReleased = false;
    }

    void setDragPosition(Offset? position) {
      if (dragDisposed) return;
      dragPosition?.value = position;
    }

    void releaseDragAt(Offset position) {
      if (dragDisposed || dragReleased) return;
      dragReleased = true;
      dragPosition?.value = position;
      final release = dragRelease;
      if (release != null) {
        release.value = release.value + 1;
      }
      detachPointerRoute();
    }

    void attachPointerRoute(PointerDownEvent downEvent) {
      detachPointerRoute();
      dragPointer = downEvent.pointer;
      dragPointerRoute = (event) {
        if (event is PointerMoveEvent) {
          setDragPosition(event.position);
        } else if (event is PointerUpEvent) {
          releaseDragAt(event.position);
        } else if (event is PointerCancelEvent) {
          setDragPosition(null);
          detachPointerRoute();
        }
      };
      GestureBinding.instance.pointerRouter.addRoute(
        downEvent.pointer,
        dragPointerRoute!,
      );
    }

    void disposeDragNotifiers() {
      if (dragDisposed) return;
      detachPointerRoute();
      dragDisposed = true;
      dragPosition?.dispose();
      dragRelease?.dispose();
      dragPosition = null;
      dragRelease = null;
    }

    final visualChild = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: selectingMessages ? null : attachPointerRoute,
      onPointerCancel: selectingMessages
          ? null
          : (event) {
              setDragPosition(null);
              detachPointerRoute();
            },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: selectingMessages ? onToggleSelect : null,
        onLongPressStart: selectingMessages
            ? null
            : (details) {
                services.HapticFeedback.mediumImpact();
                ensureDragNotifiers();
                setDragPosition(details.globalPosition);
                _showPackageActionsDialog(
                  context,
                  details.globalPosition,
                  _measureMessageRect(context),
                  dragPosition: dragPosition!,
                  dragRelease: dragRelease!,
                ).whenComplete(disposeDragNotifiers);
              },
        onLongPressMoveUpdate: selectingMessages
            ? null
            : (details) => setDragPosition(details.globalPosition),
        onLongPressEnd: selectingMessages
            ? null
            : (details) => releaseDragAt(details.globalPosition),
        onLongPressCancel: selectingMessages
            ? null
            : () {
                setDragPosition(null);
                detachPointerRoute();
              },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (applyHighlight)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: selectingMessages
                        ? const EdgeInsets.fromLTRB(6, 3, 8, 3)
                        : EdgeInsets.only(
                            left: isMine ? 44 : 0,
                            right: isMine ? 0 : 44,
                          ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: isSelected
                              ? 0.16
                              : (selectingMessages ? 0.04 : 0.045),
                        ),
                        borderRadius: BorderRadius.circular(
                          selectingMessages ? 22 : 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(left: selectingMessages ? 40 : 0),
              child: IgnorePointer(
                ignoring: selectingMessages,
                child: child,
              ),
            ),
            if (selectingMessages)
              Positioned(
                left: 10,
                top: 0,
                bottom: hasReactions ? 10 : 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _SelectionIndicator(
                    selected: isSelected,
                  ),
                ),
              ),
            if (hasReactions)
              Positioned(
                left: selectingMessages && reactionLeft != null
                    ? reactionLeft! + 40
                    : reactionLeft,
                right: reactionRight,
                bottom: -10,
                child: fcr.StackedReactions(
                  messageId: message.id,
                  controller: controller,
                  size: 27,
                  stackedValue: 5,
                  maxReactionsToShow: 4,
                  direction: isMine ? TextDirection.rtl : TextDirection.ltr,
                  reactionBackgroundColor: theme.colorScheme.surface,
                  onTap: onReact,
                  customReactionBuilder: (emoji, count, isUserReacted) {
                    return _MessageReactionBubble(
                      emoji: emoji,
                      count: count,
                      selected: isUserReacted,
                      isMine: isMine,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );

    return visualChild;
  }

  fcr.ReactionsController _buildPackageController() {
    final userId = currentUserId?.isNotEmpty == true ? currentUserId! : 'me';
    final controller = fcr.ReactionsController(currentUserId: userId);
    final loaded = <fcr.Reaction>[];
    final userReactions = message.userReactions?.toSet() ?? const <String>{};

    for (final entry in reactions.entries) {
      var remaining = entry.value;
      if (remaining <= 0) continue;

      if (userReactions.contains(entry.key)) {
        loaded.add(
          fcr.Reaction(
            emoji: entry.key,
            userId: userId,
            timestamp: message.at,
          ),
        );
        remaining -= 1;
      }

      for (var i = 0; i < remaining; i++) {
        loaded.add(
          fcr.Reaction(
            emoji: entry.key,
            userId: '${message.id}_${entry.key}_$i',
            timestamp: message.at,
          ),
        );
      }
    }

    controller.loadReactions(message.id, loaded);
    return controller;
  }

  bool get _hasImagePreview =>
      message.imagePath?.isNotEmpty == true ||
      (message.attachments ?? const []).any((file) => file.isImage);

  double _estimatedPreviewHeight(double maxPreviewHeight) {
    if (_hasImagePreview)
      return maxPreviewHeight.clamp(160.0, 260.0).toDouble();
    if (_isForwardGroupPreview) {
      return maxPreviewHeight.clamp(210.0, 330.0).toDouble();
    }
    if (message.type == MessageType.file) {
      return message.text.trim().isNotEmpty ? 128.0 : 92.0;
    }
    if (message.type == MessageType.assignmentDraft ||
        message.type == MessageType.assignmentPublished) {
      return 126.0;
    }
    return 76.0;
  }

  bool get _isForwardGroupPreview => message.text.contains('__FG__:');

  Rect? _measureMessageRect(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final overlayBox = overlay?.context.findRenderObject();
    if (overlayBox is! RenderBox) return null;
    final topLeft = renderObject.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    return topLeft & renderObject.size;
  }

  Future<void> _showPackageActionsDialog(
    BuildContext context,
    Offset pressPosition,
    Rect? targetRect, {
    required ValueListenable<Offset?> dragPosition,
    required ValueListenable<int> dragRelease,
  }) {
    final menuItems = _buildMenuItems();

    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'message_reactions',
      barrierColor: Colors.black.withValues(alpha: 0.24),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final mq = MediaQuery.of(dialogContext);
        final screen = mq.size;
        final safeTop = mq.padding.top + 10;
        final safeBottom = mq.padding.bottom + 10;
        final maxPreviewW = (screen.width - 48).clamp(220.0, 360.0);
        final maxPreviewH =
            (screen.height - safeTop - safeBottom - 190).clamp(120.0, 360.0);
        final align =
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
        final contentW = maxPreviewW.toDouble();
        final previewH = _estimatedPreviewHeight(maxPreviewH.toDouble());
        const reactionH = 40.0;
        const gap = 8.0;
        const horizontalGap = 24.0;
        const menuW = 220.0;
        final menuH = (menuItems.length * 42.0) + 8.0;
        final targetY = targetRect?.center.dy ?? pressPosition.dy;
        final contentLeft =
            isMine ? screen.width - horizontalGap - contentW : horizontalGap;
        final bottomLimit = screen.height - safeBottom;
        final previewTopCandidate = targetY - previewH / 2;
        final menuBelowFits =
            previewTopCandidate + previewH + gap + menuH <= bottomLimit;
        final menuAbove = targetY > screen.height * 0.54 || !menuBelowFits;
        final totalH = reactionH + gap + previewH + gap + menuH;
        final topCandidate = menuAbove
            ? targetY - previewH / 2 - menuH - gap - reactionH - gap
            : targetY - previewH / 2 - reactionH - gap;
        final maxDialogTop = bottomLimit - totalH;
        final effectiveMaxTop = maxDialogTop < safeTop ? safeTop : maxDialogTop;
        final dialogTop = topCandidate
            .clamp(safeTop, effectiveMaxTop)
            .toDouble()
            .clamp(safeTop, bottomLimit - 120.0)
            .toDouble();
        final availableH = (bottomLimit - dialogTop).clamp(120.0, totalH);

        var actionCommitted = false;

        void dismissDialogOnly() {
          if (!dialogContext.mounted) return;
          Navigator.of(dialogContext).pop();
        }

        void commitMenuAction(String label) {
          if (actionCommitted) return;
          actionCommitted = true;
          dismissDialogOnly();
          onMenuAction?.call(label);
        }

        void commitReaction(String emoji) {
          if (actionCommitted) return;
          actionCommitted = true;
          dismissDialogOnly();
          onReactionSelected(emoji);
        }

        return _PackageActionsDialogShell(
          onBackdropTap: () {
            if (actionCommitted) return;
            dismissDialogOnly();
          },
          child: Positioned(
            top: dialogTop,
            left: contentLeft,
            width: contentW,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: contentW,
                maxHeight: availableH.toDouble(),
              ),
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: align,
                  children: [
                    if (menuAbove) ...[
                      _PackageActionsMenu(
                        menuItems: menuItems,
                        width: menuW,
                        isDark: Theme.of(dialogContext).brightness ==
                            Brightness.dark,
                        dragPosition: dragPosition,
                        dragRelease: dragRelease,
                        onTap: (item) => commitMenuAction(item.label),
                      ),
                      const SizedBox(height: gap),
                    ],
                    _PackageReactionPicker(
                      reactions: const ['👍', '❤️', '😂', '😮', '😢', '😡'],
                      onSelected: commitReaction,
                    ),
                    const SizedBox(height: gap),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: contentW,
                        maxHeight: _isForwardGroupPreview
                            ? maxPreviewH.toDouble().clamp(220.0, 340.0)
                            : maxPreviewH.toDouble(),
                      ),
                      child: _isForwardGroupPreview
                          ? _PackageMessagePreview(
                              message: message,
                              liftBrightness: isMine,
                              child: previewChild,
                            )
                          : IgnorePointer(
                              child: _PackageMessagePreview(
                                message: message,
                                liftBrightness: isMine,
                                child: previewChild,
                              ),
                            ),
                    ),
                    if (!menuAbove) ...[
                      const SizedBox(height: gap),
                      _PackageActionsMenu(
                        menuItems: menuItems,
                        width: menuW,
                        isDark: Theme.of(dialogContext).brightness ==
                            Brightness.dark,
                        dragPosition: dragPosition,
                        dragRelease: dragRelease,
                        onTap: (item) => commitMenuAction(item.label),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
      },
    );
  }

  List<fcr.MenuItem> _buildMenuItems() {
    final items = <fcr.MenuItem>[
      const fcr.MenuItem(label: 'Ответить', icon: Icons.reply),
    ];

    if (message.text.trim().isNotEmpty) {
      items.add(const fcr.MenuItem(label: 'Скопировать', icon: Icons.copy));
    }

    if (canEdit) {
      items.add(const fcr.MenuItem(label: 'Изменить', icon: Icons.edit));
    }

    items.addAll([
      fcr.MenuItem(
        label: message.isPinned ? 'Открепить' : 'Закрепить',
        icon: Icons.push_pin,
      ),
      const fcr.MenuItem(label: 'Переслать', icon: Icons.reply),
      if (canDelete)
        const fcr.MenuItem(
          label: 'Удалить',
          icon: Icons.delete,
          isDestructive: true,
        ),
      const fcr.MenuItem(label: 'Выбрать', icon: Icons.check),
    ]);

    return items;
  }
}

class _MessageReactionBubble extends StatelessWidget {
  final String emoji;
  final int count;
  final bool selected;
  final bool isMine;

  const _MessageReactionBubble({
    required this.emoji,
    required this.count,
    required this.selected,
    required this.isMine,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = isMine ? scheme.primary : scheme.outlineVariant;

    return Container(
      constraints: const BoxConstraints(minWidth: 30, minHeight: 23),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.98)
            : scheme.surface.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent.withValues(alpha: selected ? 0.52 : 0.34),
          width: 0.7,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        count > 1 ? '$emoji $count' : emoji,
        maxLines: 1,
        style: theme.textTheme.labelMedium?.copyWith(
          fontSize: count > 1 ? 13.5 : 14.5,
          fontWeight: FontWeight.w800,
          height: 1,
          color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SelectionIndicator extends StatelessWidget {
  final bool selected;

  const _SelectionIndicator({
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.35),
          width: 1.6,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? const Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: 15,
            )
          : const SizedBox.shrink(),
    );
  }
}

const double _packageMenuItemHeight = 42.0;

/// Backdrop + content layers for the message actions dialog.
///
/// The dismiss [GestureDetector] stays on the backdrop only so menu
/// [Listener] taps do not also trigger [Navigator.pop].
class _PackageActionsDialogShell extends StatelessWidget {
  final VoidCallback onBackdropTap;
  final Widget child;

  const _PackageActionsDialogShell({
    required this.onBackdropTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBackdropTap,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

@visibleForTesting
Widget debugPackageActionsDialogShell({
  required VoidCallback onBackdropTap,
  required Widget child,
}) {
  return _PackageActionsDialogShell(
    onBackdropTap: onBackdropTap,
    child: child,
  );
}

@visibleForTesting
Widget debugPackageActionsMenu({
  required List<fcr.MenuItem> menuItems,
  required ValueListenable<Offset?> dragPosition,
  required ValueListenable<int> dragRelease,
  required void Function(fcr.MenuItem item) onTap,
  double width = 220,
  bool isDark = false,
}) {
  return _PackageActionsMenu(
    menuItems: menuItems,
    width: width,
    isDark: isDark,
    dragPosition: dragPosition,
    dragRelease: dragRelease,
    onTap: onTap,
  );
}

class _PackageActionsMenu extends StatefulWidget {
  final List<fcr.MenuItem> menuItems;
  final double width;
  final bool isDark;
  final ValueListenable<Offset?> dragPosition;
  final ValueListenable<int> dragRelease;
  final void Function(fcr.MenuItem item) onTap;

  const _PackageActionsMenu({
    required this.menuItems,
    required this.width,
    required this.isDark,
    required this.dragPosition,
    required this.dragRelease,
    required this.onTap,
  });

  @override
  State<_PackageActionsMenu> createState() => _PackageActionsMenuState();
}

class _PackageActionsMenuState extends State<_PackageActionsMenu> {
  late List<GlobalKey> _itemKeys;
  final _menuKey = GlobalKey();
  int? _selectedIndex;
  int _handledReleaseTick = 0;
  bool _menuPointerActive = false;
  bool _actionCommitted = false;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.menuItems.length, (_) => GlobalKey());
    widget.dragPosition.addListener(_handleDragPosition);
    widget.dragRelease.addListener(_handleDragRelease);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleDragPosition());
  }

  @override
  void didUpdateWidget(covariant _PackageActionsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dragPosition != widget.dragPosition) {
      oldWidget.dragPosition.removeListener(_handleDragPosition);
      widget.dragPosition.addListener(_handleDragPosition);
    }
    if (oldWidget.dragRelease != widget.dragRelease) {
      oldWidget.dragRelease.removeListener(_handleDragRelease);
      widget.dragRelease.addListener(_handleDragRelease);
    }
    if (oldWidget.menuItems.length != widget.menuItems.length) {
      _itemKeys = List.generate(widget.menuItems.length, (_) => GlobalKey());
      _selectedIndex = null;
    }
  }

  @override
  void dispose() {
    widget.dragPosition.removeListener(_handleDragPosition);
    widget.dragRelease.removeListener(_handleDragRelease);
    super.dispose();
  }

  void _handleDragPosition() {
    if (!mounted) return;
    final position = widget.dragPosition.value;
    _selectIndex(position == null ? null : _hitTest(position));
  }

  void _selectIndex(int? nextIndex, {bool haptic = true}) {
    if (nextIndex == _selectedIndex) return;
    setState(() => _selectedIndex = nextIndex);
    if (haptic && nextIndex != null) {
      services.HapticFeedback.selectionClick();
    }
  }

  void _selectAtMenuPosition(
    Offset globalPosition, {
    bool haptic = true,
  }) {
    _selectIndex(_hitTest(globalPosition), haptic: haptic);
  }

  void _activateSelected([int? explicitIndex]) {
    _commitAction(explicitIndex ?? _selectedIndex);
  }

  void _commitAction(int? index) {
    if (_actionCommitted) return;
    if (index == null || index < 0 || index >= widget.menuItems.length) {
      return;
    }
    _actionCommitted = true;
    widget.onTap(widget.menuItems[index]);
  }

  void _handleDragRelease() {
    if (!mounted || widget.dragRelease.value == _handledReleaseTick) return;
    _handledReleaseTick = widget.dragRelease.value;
    if (_actionCommitted) return;

    final position = widget.dragPosition.value;
    final index =
        _selectedIndex ?? (position == null ? null : _hitTest(position));
    _commitAction(index);
  }

  int? _hitTest(Offset globalPosition) {
    Rect? menuBounds;
    final rowRects = <Rect>[];

    for (final key in _itemKeys) {
      final context = key.currentContext;
      final renderObject = context?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;
      final topLeft = renderObject.localToGlobal(Offset.zero);
      final rect = topLeft & renderObject.size;
      rowRects.add(rect);
      menuBounds = menuBounds == null ? rect : menuBounds.expandToInclude(rect);
    }

    for (var i = 0; i < rowRects.length; i++) {
      if (rowRects[i].contains(globalPosition)) return i;
    }

    final bounds = menuBounds;
    if (bounds == null) return null;

    // Long-press selection on a phone should feel forgiving: after the menu
    // opens, users often keep their finger near the message edge rather than
    // exactly inside the narrow action panel. Match rows by vertical position
    // while allowing a horizontal gutter around the menu.
    const horizontalSlop = 140.0;
    if (globalPosition.dx < bounds.left - horizontalSlop ||
        globalPosition.dx > bounds.right + horizontalSlop) {
      return null;
    }

    for (var i = 0; i < rowRects.length; i++) {
      final row = rowRects[i];
      if (globalPosition.dy >= row.top && globalPosition.dy <= row.bottom) {
        return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = _selectedIndex;
    final highlightColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.07);

    return SizedBox(
      width: widget.width,
      child: Listener(
        key: _menuKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _menuPointerActive = true;
          _selectAtMenuPosition(event.position, haptic: false);
        },
        onPointerMove: (event) {
          if (!_menuPointerActive) return;
          _selectAtMenuPosition(event.position);
        },
        onPointerUp: (event) {
          if (!_menuPointerActive) return;
          final index = _hitTest(event.position);
          _selectIndex(index, haptic: false);
          _menuPointerActive = false;
          _activateSelected(index);
        },
        onPointerCancel: (_) {
          _menuPointerActive = false;
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.isDark ? const Color(0xFF1D1D1F) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                if (selectedIndex != null)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 130),
                    curve: Curves.easeOutCubic,
                    left: 5,
                    right: 5,
                    top: selectedIndex * _packageMenuItemHeight + 4,
                    height: _packageMenuItemHeight - 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: highlightColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.menuItems.length; i++)
                      _PackageMenuItemTile(
                        key: _itemKeys[i],
                        item: widget.menuItems[i],
                        selected: selectedIndex == i,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PackageMenuItemTile extends StatelessWidget {
  final fcr.MenuItem item;
  final bool selected;

  const _PackageMenuItemTile({
    super.key,
    required this.item,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = item.isDestructive
        ? Colors.redAccent
        : (isDark ? Colors.white : Colors.black87);
    final fontWeight = selected ? FontWeight.w700 : FontWeight.w500;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: _packageMenuItemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(item.icon, color: color, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: fontWeight,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackageReactionPicker extends StatelessWidget {
  final List<String> reactions;
  final void Function(String emoji) onSelected;

  const _PackageReactionPicker({
    required this.reactions,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final emoji in reactions)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => services.HapticFeedback.selectionClick(),
                  onTap: () => onSelected(emoji),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Text(
                      emoji,
                      style: const TextStyle(fontSize: 24, height: 1),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackageMessagePreview extends StatelessWidget {
  final Message message;
  final bool liftBrightness;
  final Widget child;

  const _PackageMessagePreview({
    required this.message,
    required this.liftBrightness,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isForwardGroup = message.text.contains('__FG__:');

    if (message.type == MessageType.assignmentDraft ||
        message.type == MessageType.assignmentPublished) {
      return _StaticAssignmentMenuPreview(message: message);
    }

    final previewContent = SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Material(
        color: Colors.transparent,
        child: child,
      ),
    );

    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: isForwardGroup
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: previewContent,
            )
          : previewContent,
    );

    if (!liftBrightness) return preview;

    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        1.08,
        0,
        0,
        0,
        8,
        0,
        1.08,
        0,
        0,
        8,
        0,
        0,
        1.08,
        0,
        8,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: preview,
    );
  }
}

class _StaticAssignmentMenuPreview extends StatelessWidget {
  final Message message;

  const _StaticAssignmentMenuPreview({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title =
        message.text.trim().isNotEmpty ? message.text.trim() : 'Задание';
    final status = message.type == MessageType.assignmentPublished
        ? 'Опубликовано'
        : 'Черновик';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.22),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.assignment_outlined, color: scheme.primary, size: 20),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    status,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatLoadErrorState extends StatelessWidget {
  const _ChatLoadErrorState({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: .45),
            ),
            const SizedBox(height: 12),
            Text(
              'Не удалось загрузить сообщения',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Проверьте соединение и попробуйте снова.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: .62),
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Повторить'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyChatState extends StatelessWidget {
  final bool isDirectChat;
  final VoidCallback? onFocusComposer;
  final VoidCallback? onAttachFile;
  final VoidCallback? onCreateAssignment;

  const _EmptyChatState({
    this.isDirectChat = false,
    this.onFocusComposer,
    this.onAttachFile,
    this.onCreateAssignment,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 56,
            color: theme.colorScheme.primary.withValues(alpha: .45),
          ),
          const SizedBox(height: 14),
          Text(
            'Сообщений пока нет',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            isDirectChat
                ? 'Напишите первое сообщение.'
                : 'Обсуждайте предмет, прикрепляйте файлы и создавайте задания для группы.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: .62),
              height: 1.25,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onFocusComposer != null)
                FilledButton.tonalIcon(
                  onPressed: onFocusComposer,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Написать'),
                ),
              if (onAttachFile != null)
                OutlinedButton.icon(
                  onPressed: onAttachFile,
                  icon: const Icon(Icons.attach_file_rounded, size: 18),
                  label: const Text('Файл'),
                ),
              if (onCreateAssignment != null)
                OutlinedButton.icon(
                  onPressed: onCreateAssignment,
                  icon: const Icon(Icons.assignment_add, size: 18),
                  label: const Text('Задание'),
                ),
            ],
          ),
          if (!isDirectChat) ...[
            const SizedBox(height: 10),
            Text(
              'Файлы появятся во вкладке «Файлы», а задания — во вкладке «Задания».',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.2,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

class _NewMessagesChip extends StatelessWidget {
  const _NewMessagesChip();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
                width: 0.5,
              ),
            ),
            child: Text(
              'Новые сообщения',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockedAuthorMessagePlaceholder extends StatelessWidget {
  const _BlockedAuthorMessagePlaceholder({required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Сообщение заблокированного пользователя',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            onPressed: onShow,
            child: const Text('Показать'),
          ),
        ],
      ),
    );
  }
}
