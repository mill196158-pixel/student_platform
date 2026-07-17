// lib/src/ui/learning/tabs/chat/actions/chat_actions.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart' as services;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../models/message.dart';
import '../../../models/assignment.dart';
import '../../../models/chat_file.dart';
import '../../../state/team_cubit.dart';
import '../message_builder.dart';

class ChatActions {
  // компактный набор реакций
  static const List<String> _reactions = ['👍', '❤️', '😂', '😮', '😢', '😡'];

  // удалять — только свои и в пределах 12 часов
  static bool _canDelete(Message m) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty || m.authorId != uid) return false;
    return DateTime.now().difference(m.at) <= const Duration(hours: 12);
  }

  // редактировать — свои текстовые младше 12 часов
  static bool _canEdit(Message m) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty || m.authorId != uid) return false;
    if (m.isSystem || m.isLocal) return false;
    if (m.type != MessageType.text) return false;
    if (m.forward != null) return false;
    if (m.text.contains('__FG__:')) return false;
    if (m.attachments != null && m.attachments!.isNotEmpty) return false;
    if (m.text.trim().isEmpty) return false;
    return DateTime.now().difference(m.at) <= const Duration(hours: 12);
  }

  // посчитать “естественную” ширину панели по самому длинному тексту
  static double _calcPanelWidth({
    required BuildContext context,
    required List<String> labels,
    required double minW,
    required double maxW,
  }) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    double longest = 0;
    for (final s in labels) {
      tp.text = TextSpan(text: s, style: const TextStyle(fontSize: 14));
      tp.layout();
      longest = math.max(longest, tp.width);
    }
    // левая паддинга 12 + иконка 20 + зазор 10 + текст + правая паддинга 12
    final content = 12 + 20 + 10 + longest + 12;
    final effectiveMin = math.min(minW, maxW);
    return content.clamp(effectiveMin, maxW).toDouble();
  }

  /// Главное меню действий по сообщению (blur overlay)
  static Future<void> showMessageActions(
    BuildContext context,
    Message message, {
    Rect? targetRect,
    Uint8List? bubbleBytes,
    String? replyPreview,
    Offset? fallbackPosition,
    required void Function() onReply,
    required VoidCallback onForward,
    required Future<void> Function() onTogglePin,
    required Future<void> Function() onDeleteIfAllowed,
    Future<void> Function()? onEditIfAllowed,
    required void Function(String emoji) onReact,
    required void Function() onSelect,
  }) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'message_actions',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      pageBuilder: (ctx, anim1, anim2) {
        final mq = MediaQuery.of(ctx);
        final w = mq.size.width;
        final h = mq.size.height;
        final safeTop = mq.padding.top + 8;
        final safeBottom = mq.padding.bottom + 8;

        // Геометрия
        const gapBubble = 4.0;
        const gapBetween = 6.0;
        const reactionH = 48.0;
        const tileH = _contextMenuItemHeight;

        final hasDelete = _canDelete(message);
        final hasEdit = _canEdit(message) && onEditIfAllowed != null;
        final hasText = message.text.trim().isNotEmpty;
        final isPinned = message.isPinned;

        // список ярлыков, чтобы посчитать ширину
        final labels = <String>[
          'Ответить',
          if (hasText) 'Скопировать',
          if (hasEdit) 'Изменить',
          isPinned ? 'Открепить' : 'Закрепить',
          'Переслать',
          if (hasDelete) 'Удалить',
          'Выбрать',
        ];

        final tilesCount = labels.length;
        final actionsFullH = tilesCount * tileH;

        final noRect = targetRect == null;

        return BlocProvider.value(
          value: context.read<TeamCubit>(),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(ctx),
              child: SafeArea(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Stack(
                    children: [
                      // liquid glass
                      Positioned.fill(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: Container(
                              color: Colors.black.withValues(alpha: 0.35)),
                        ),
                      ),

                      if (noRect)
                        _buildCenteredOverlay(
                          ctx: ctx,
                          screenW: w,
                          screenH: h,
                          safeTop: safeTop,
                          safeBottom: safeBottom,
                          fallbackPosition: fallbackPosition,
                          reactionH: reactionH,
                          gapBetween: gapBetween,
                          actionsFullH: actionsFullH,
                          labels: labels,
                          message: message,
                          replyPreview: replyPreview,
                          hasText: hasText,
                          onReply: onReply,
                          onForward: onForward,
                          onReact: onReact,
                          onTogglePin: onTogglePin,
                          onDeleteIfAllowed: onDeleteIfAllowed,
                          onEditIfAllowed: hasEdit ? onEditIfAllowed : null,
                          onSelect: onSelect,
                        )
                      else
                        _buildAnchoredOverlay(
                          ctx: ctx,
                          screenW: w,
                          screenH: h,
                          safeTop: safeTop,
                          safeBottom: safeBottom,
                          bubble: targetRect,
                          reactionH: reactionH,
                          gapBubble: gapBubble,
                          gapBetween: gapBetween,
                          actionsFullH: actionsFullH,
                          labels: labels,
                          message: message,
                          replyPreview: replyPreview,
                          hasText: hasText,
                          onReply: onReply,
                          onForward: onForward,
                          onReact: onReact,
                          onTogglePin: onTogglePin,
                          onDeleteIfAllowed: onDeleteIfAllowed,
                          onEditIfAllowed: hasEdit ? onEditIfAllowed : null,
                          onSelect: onSelect,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------- Вспомогательные билдеры overlay ----------

  static Widget _buildCenteredOverlay({
    required BuildContext ctx,
    required double screenW,
    required double screenH,
    required double safeTop,
    required double safeBottom,
    required Offset? fallbackPosition,
    required double reactionH,
    required double gapBetween,
    required double actionsFullH,
    required List<String> labels,
    required Message message,
    required String? replyPreview,
    required bool hasText,
    required VoidCallback onReply,
    required VoidCallback onForward,
    required void Function(String) onReact,
    required Future<void> Function() onTogglePin,
    required Future<void> Function() onDeleteIfAllowed,
    Future<void> Function()? onEditIfAllowed,
    required VoidCallback onSelect,
  }) {
    final double panelMaxW = (screenW - 32).clamp(160.0, 520.0).toDouble();
    final double actionsW = _calcPanelWidth(
      context: ctx,
      labels: labels,
      minW: 188,
      maxW: math.min(240.0, panelMaxW),
    );
    final double pillW = 300.0.clamp(160.0, panelMaxW);

    final totalH = reactionH + gapBetween + actionsFullH;
    final anchor = fallbackPosition ?? Offset(screenW / 2, screenH / 2);
    final top = (anchor.dy - totalH / 2)
        .clamp(safeTop + 8, screenH - safeBottom - totalH - 8)
        .toDouble();

    final pillLeft =
        (anchor.dx - pillW / 2).clamp(16.0, screenW - pillW - 16.0);
    final actionsLeft =
        (anchor.dx - actionsW / 2).clamp(16.0, screenW - actionsW - 16.0);

    return _OverlayStack(
      bubbleRect: Rect.zero,
      reactionRect: Rect.fromLTWH(pillLeft, top, pillW, reactionH),
      actionsRect: Rect.fromLTWH(
          actionsLeft, top + reactionH + gapBetween, actionsW, actionsFullH),
      showClone: false,
      message: message,
      replyPreview: replyPreview,
      onReact: (e) {
        Navigator.pop(ctx);
        onReact(e);
      },
      onReply: () {
        Navigator.pop(ctx);
        onReply();
      },
      onForward: () {
        Navigator.pop(ctx);
        onForward();
      },
      onCopy: hasText
          ? () async {
              Navigator.pop(ctx);
              final t = message.text;
              if (t.isNotEmpty) {
                await services.Clipboard.setData(
                    services.ClipboardData(text: t));
              }
            }
          : null,
      onEdit: onEditIfAllowed == null
          ? null
          : () async {
              Navigator.pop(ctx);
              await onEditIfAllowed();
            },
      onPin: () async {
        Navigator.pop(ctx);
        await onTogglePin();
      },
      onDelete: _canDelete(message)
          ? () async {
              Navigator.pop(ctx);
              await onDeleteIfAllowed();
            }
          : null,
      onSelect: () {
        Navigator.pop(ctx);
        onSelect();
      },
    );
  }

  static Widget _buildAnchoredOverlay({
    required BuildContext ctx,
    required double screenW,
    required double screenH,
    required double safeTop,
    required double safeBottom,
    required Rect bubble,
    required double reactionH,
    required double gapBubble,
    required double gapBetween,
    required double actionsFullH,
    required List<String> labels,
    required Message message,
    required String? replyPreview,
    required bool hasText,
    required VoidCallback onReply,
    required VoidCallback onForward,
    required void Function(String) onReact,
    required Future<void> Function() onTogglePin,
    required Future<void> Function() onDeleteIfAllowed,
    Future<void> Function()? onEditIfAllowed,
    required VoidCallback onSelect,
  }) {
    const double edgeGap = 8.0;

    // пределы ширины
    final double panelMaxW = (screenW - 32).clamp(160.0, 520.0).toDouble();
    final double actionsW = _calcPanelWidth(
      context: ctx,
      labels: labels,
      minW: 188,
      maxW: math.min(240.0, panelMaxW),
    );

    // Пилюля — центр по баблу, чуть уже бабла; скролл если не влезает
    const double emojiSize = 22.0;
    const double spacing = 8.0;
    const double pillHPad = 16.0;
    final double desiredPillW =
        _reactions.length * (emojiSize + spacing) + pillHPad;
    final double pillW = desiredPillW.clamp(160.0, math.min(300.0, panelMaxW));

    double clampLeft(double left, double width) =>
        left.clamp(16.0, screenW - width - 16.0);

    final double pillLeft =
        clampLeft(bubble.left + (bubble.width - pillW) / 2, pillW);

    final userId = Supabase.instance.client.auth.currentUser?.id;
    final isMe = message.isMine(userId);
    final double actionsLeft = clampLeft(
      isMe ? (bubble.right - actionsW) : bubble.left,
      actionsW,
    );

    final above = bubble.top - safeTop;
    final needAll = gapBubble + reactionH + gapBetween + actionsFullH;
    final placeAbove = above >= needAll;

    late Rect reactionRect, actionsRect;

    if (placeAbove) {
      final double reactionTop = (bubble.top - gapBubble - reactionH)
          .clamp(safeTop + edgeGap, screenH.toDouble());
      final double actionsBottom = reactionTop - gapBetween;
      final double actionsTop =
          math.max(safeTop + edgeGap, actionsBottom - actionsFullH);

      reactionRect = Rect.fromLTWH(pillLeft, reactionTop, pillW, reactionH);
      actionsRect = Rect.fromLTWH(
          actionsLeft, actionsTop, actionsW, actionsBottom - actionsTop);
    } else {
      final double reactionTop = (bubble.bottom + gapBubble)
          .clamp(safeTop + edgeGap, screenH - safeBottom - edgeGap - reactionH);
      final double actionsTop = reactionTop + reactionH + gapBetween;
      final double actionsBottom =
          math.min(screenH - safeBottom - edgeGap, actionsTop + actionsFullH);

      reactionRect = Rect.fromLTWH(pillLeft, reactionTop, pillW, reactionH);
      actionsRect = Rect.fromLTWH(
          actionsLeft, actionsTop, actionsW, (actionsBottom - actionsTop));
    }

    return _OverlayStack(
      bubbleRect: bubble,
      reactionRect: reactionRect,
      actionsRect: actionsRect,
      message: message,
      replyPreview: replyPreview,
      onReact: (e) {
        Navigator.pop(ctx);
        onReact(e);
      },
      onReply: () {
        Navigator.pop(ctx);
        onReply();
      },
      onForward: () {
        Navigator.pop(ctx);
        onForward();
      },
      onCopy: hasText
          ? () async {
              Navigator.pop(ctx);
              final t = message.text;
              if (t.isNotEmpty) {
                await services.Clipboard.setData(
                    services.ClipboardData(text: t));
              }
            }
          : null,
      onEdit: onEditIfAllowed == null
          ? null
          : () async {
              Navigator.pop(ctx);
              await onEditIfAllowed();
            },
      onPin: () async {
        Navigator.pop(ctx);
        await onTogglePin();
      },
      onDelete: _canDelete(message)
          ? () async {
              Navigator.pop(ctx);
              await onDeleteIfAllowed();
            }
          : null,
      onSelect: () {
        Navigator.pop(ctx);
        onSelect();
      },
    );
  }

  // ---------- Служебные листы (без изменений UI) ----------

  static Future<void> showAssignmentActions(
    BuildContext context,
    Assignment assignment, {
    required void Function() onOpen,
    required void Function() onVote,
    required void Function() onPin,
  }) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Открыть'),
              onTap: () {
                Navigator.pop(ctx);
                onOpen();
              },
            ),
            ListTile(
              leading: const Icon(Icons.thumb_up),
              title: const Text('Проголосовать'),
              onTap: () {
                Navigator.pop(ctx);
                onVote();
              },
            ),
            ListTile(
              leading: const Icon(Icons.push_pin),
              title: const Text('Закрепить'),
              onTap: () {
                Navigator.pop(ctx);
                onPin();
              },
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> showFileActions(
    BuildContext context,
    ChatFile file, {
    required void Function() onDownload,
    required void Function() onOpen,
    required void Function() onShare,
  }) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Скачать'),
              onTap: () {
                Navigator.pop(ctx);
                onDownload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Открыть'),
              onTap: () {
                Navigator.pop(ctx);
                onOpen();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Поделиться'),
              onTap: () {
                Navigator.pop(ctx);
                onShare();
              },
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> showMultiFileActions(
    BuildContext context,
    List<ChatFile> files, {
    required void Function() onDownloadAll,
    required void Function() onOpenAll,
  }) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Скачать все'),
              onTap: () {
                Navigator.pop(ctx);
                onDownloadAll();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Открыть все'),
              onTap: () {
                Navigator.pop(ctx);
                onOpenAll();
              },
            ),
          ],
        ),
      ),
    );
  }

  // Центрированный пикер реакций (для вызовов вне лонгтапа)
  static void showReactionPicker(
    BuildContext context,
    void Function(String emoji) onReact,
  ) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'reaction_picker',
      barrierColor: Colors.black.withValues(alpha: 0.35),
      pageBuilder: (ctx, anim1, anim2) {
        final mq = MediaQuery.of(ctx);
        final w = mq.size.width;
        final h = mq.size.height;

        const pillH = 48.0;
        final double pillW =
            (mq.size.width * 0.72).clamp(180.0, 520.0).toDouble();

        return FadeTransition(
          opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
          child: GestureDetector(
            onTap: () => Navigator.pop(ctx),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: Container(
                          color: Colors.black.withValues(alpha: 0.35)),
                    ),
                  ),
                  Positioned(
                    left: (w - pillW) / 2,
                    top: (h - pillH) / 2,
                    width: pillW,
                    height: pillH,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: _reactions.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (_, i) {
                          final e = _reactions[i];
                          return GestureDetector(
                            onTap: () {
                              Navigator.pop(ctx);
                              onReact(e);
                            },
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child:
                                  Text(e, style: const TextStyle(fontSize: 20)),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

const double _contextMenuItemHeight = 42.0;

class _ContextAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _ContextAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
}

class _ContextActionsMenu extends StatefulWidget {
  final List<_ContextAction> actions;
  final double width;
  final double maxHeight;

  const _ContextActionsMenu({
    required this.actions,
    required this.width,
    required this.maxHeight,
  });

  @override
  State<_ContextActionsMenu> createState() => _ContextActionsMenuState();
}

class _ContextActionsMenuState extends State<_ContextActionsMenu> {
  late List<GlobalKey> _itemKeys;
  int? _selectedIndex;
  bool _pointerActive = false;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.actions.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant _ContextActionsMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actions.length != widget.actions.length) {
      _itemKeys = List.generate(widget.actions.length, (_) => GlobalKey());
      _selectedIndex = null;
    }
  }

  void _selectIndex(int? nextIndex, {bool haptic = true}) {
    if (nextIndex == _selectedIndex) return;
    setState(() => _selectedIndex = nextIndex);
    if (haptic && nextIndex != null) {
      services.HapticFeedback.selectionClick();
    }
  }

  void _selectAtPosition(Offset globalPosition, {bool haptic = true}) {
    _selectIndex(_hitTest(globalPosition), haptic: haptic);
  }

  void _activateSelected() {
    final index = _selectedIndex;
    if (index == null || index < 0 || index >= widget.actions.length) return;
    widget.actions[index].onTap();
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = isDark ? const Color(0xFF1D1D1F) : Colors.white;
    final highlightColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.07);
    final contentHeight = widget.actions.length * _contextMenuItemHeight;

    return SizedBox(
      width: widget.width,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            _pointerActive = true;
            _selectAtPosition(event.position, haptic: false);
          },
          onPointerMove: (event) {
            if (!_pointerActive) return;
            _selectAtPosition(event.position);
          },
          onPointerUp: (event) {
            if (!_pointerActive) return;
            _selectAtPosition(event.position, haptic: false);
            _pointerActive = false;
            _activateSelected();
          },
          onPointerCancel: (_) {
            _pointerActive = false;
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
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
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: SizedBox(
                  height: contentHeight,
                  child: Stack(
                    children: [
                      if (selectedIndex != null)
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 130),
                          curve: Curves.easeOutCubic,
                          left: 5,
                          right: 5,
                          top: selectedIndex * _contextMenuItemHeight + 4,
                          height: _contextMenuItemHeight - 8,
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
                          for (var i = 0; i < widget.actions.length; i++)
                            _ContextMenuItemTile(
                              key: _itemKeys[i],
                              action: widget.actions[i],
                              selected: selectedIndex == i,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextMenuItemTile extends StatelessWidget {
  final _ContextAction action;
  final bool selected;

  const _ContextMenuItemTile({
    super.key,
    required this.action,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = action.danger
        ? Colors.redAccent
        : (isDark ? Colors.white : Colors.black87);
    final fontWeight = selected ? FontWeight.w700 : FontWeight.w500;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: _contextMenuItemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(action.icon, color: color, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  action.label,
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

/// Внутренний стек: смайлы, действия, и клон бабла под ними для фокуса.
class _OverlayStack extends StatelessWidget {
  final Rect bubbleRect;
  final Rect reactionRect;
  final Rect actionsRect;
  final bool showClone;

  final Message message;
  final String? replyPreview;

  final ValueChanged<String> onReact;
  final VoidCallback onReply;
  final Future<void> Function()? onDelete; // nullable
  final Future<void> Function()? onEdit; // nullable
  final VoidCallback onPin;
  final VoidCallback onForward;
  final Future<void> Function()? onCopy; // nullable
  final VoidCallback onSelect;

  const _OverlayStack({
    required this.bubbleRect,
    required this.reactionRect,
    required this.actionsRect,
    this.showClone = true,
    required this.message,
    required this.replyPreview,
    required this.onReact,
    required this.onReply,
    required this.onPin,
    required this.onForward,
    required this.onDelete,
    required this.onEdit,
    required this.onCopy,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final isMe = message.isMine(userId);
    final pinLabel = message.isPinned ? 'Открепить' : 'Закрепить';

    final screenW = MediaQuery.of(context).size.width;
    const double edgeGap = 16.0;
    final screenMaxW = math.max(0.0, screenW - edgeGap * 2);
    final needsWideClone = message.type == MessageType.assignmentDraft ||
        message.type == MessageType.assignmentPublished ||
        message.type == MessageType.forward ||
        message.text.contains('__FG__:') ||
        (message.attachments?.isNotEmpty ?? false);
    final minCloneW = needsWideClone ? 220.0 : 96.0;
    final measuredW = bubbleRect.width.isFinite ? bubbleRect.width : 0.0;
    final double contentW = measuredW <= 0
        ? 0.0
        : measuredW
            .clamp(
              math.min(minCloneW, screenMaxW),
              screenMaxW,
            )
            .toDouble();
    final desiredLeft = isMe ? bubbleRect.right - contentW : bubbleRect.left;
    final cloneLeft = desiredLeft
        .clamp(edgeGap, math.max(edgeGap, screenW - contentW - edgeGap))
        .toDouble();

    return Stack(
      children: [
        // Пилюля реакций (скролл, если мало ширины)
        Positioned(
          left: reactionRect.left,
          top: reactionRect.top,
          width: reactionRect.width,
          height: reactionRect.height,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(28),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: ChatActions._reactions.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final e = ChatActions._reactions[i];
                return GestureDetector(
                  onTap: () => onReact(e),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(e, style: const TextStyle(fontSize: 20)),
                  ),
                );
              },
            ),
          ),
        ),

        // Панель действий — такой же список, как в основном чате,
        // с выбором пункта при движении пальца по меню.
        Positioned(
          left: actionsRect.left,
          top: actionsRect.top,
          width: actionsRect.width,
          child: _ContextActionsMenu(
            actions: [
              _ContextAction(
                icon: Icons.reply,
                label: 'Ответить',
                onTap: onReply,
              ),
              if (onCopy != null)
                _ContextAction(
                  icon: Icons.copy,
                  label: 'Скопировать',
                  onTap: () async => await onCopy!.call(),
                ),
              if (onEdit != null)
                _ContextAction(
                  icon: Icons.edit,
                  label: 'Изменить',
                  onTap: () async => await onEdit!.call(),
                ),
              _ContextAction(
                icon: Icons.push_pin,
                label: pinLabel,
                onTap: onPin,
              ),
              _ContextAction(
                icon: Icons.reply_outlined,
                label: 'Переслать',
                onTap: onForward,
              ),
              if (onDelete != null)
                _ContextAction(
                  icon: Icons.delete,
                  label: 'Удалить',
                  onTap: () async => await onDelete!.call(),
                  danger: true,
                ),
              _ContextAction(
                icon: Icons.check,
                label: 'Выбрать',
                onTap: onSelect,
              ),
            ],
            width: actionsRect.width,
            maxHeight: actionsRect.height,
          ),
        ),

        // Клон бабла
        if (showClone && contentW > 0)
          Positioned(
            left: cloneLeft,
            top: (bubbleRect.top - 6).clamp(0.0, double.infinity).toDouble(),
            width: contentW,
            child: IgnorePointer(
              ignoring: true,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  // высоту не фиксируем, чтобы исключить overflow при клоне
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: contentW,
                          maxWidth: contentW,
                        ),
                        child: buildBubble(
                          m: message,
                          showAvatar: false,
                          reserveAvatarSpace: false,
                          time:
                              '${message.at.hour.toString().padLeft(2, '0')}:${message.at.minute.toString().padLeft(2, '0')}',
                          onLongPress: null,
                          onReply: () {},
                          onReplyTap: (id) {},
                          replyPreview: replyPreview,
                          authorAvatarUrl: null,
                          authorName: message.authorName,
                          attachments: message.attachments,
                          isMe: isMe,
                          caption: message.text,
                          reactions: const <String, Map<String, int>>{},
                          onReact: () {},
                          selected: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
