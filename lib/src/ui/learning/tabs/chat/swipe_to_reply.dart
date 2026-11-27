import 'package:flutter/material.dart';

class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  double _dx = 0;
  @override
  void didUpdateWidget(covariant SwipeToReply oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _dx = 0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: widget.enabled
          ? (d) => setState(() => _dx = (_dx + d.primaryDelta!).clamp(0, 80))
          : null,
      onHorizontalDragEnd: widget.enabled
          ? (_) {
              if (_dx > 48) widget.onReply();
              setState(() => _dx = 0);
            }
          : null,
      onHorizontalDragCancel:
          widget.enabled ? () => setState(() => _dx = 0) : null,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: widget.child,
      ),
    );
  }
}
