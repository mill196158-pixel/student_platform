import 'package:flutter/material.dart';

class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const SwipeToReply({super.key, required this.child, required this.onReply});

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  double _dx = 0;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        setState(() => _dx = (_dx + d.primaryDelta!).clamp(0, 80));
      },
      onHorizontalDragEnd: (_) {
        if (_dx > 48) widget.onReply();
        setState(() => _dx = 0);
      },
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: widget.child,
      ),
    );
  }
}
