import 'package:flutter/material.dart';
import 'scroll_to_bottom_button.dart';

class ChatList extends StatelessWidget {
  final List<Widget> children;
  final ScrollController controller;
  final bool showJump;
  final VoidCallback onJumpTap;
  final double bottomPadding;

  const ChatList({
    super.key,
    required this.children,
    required this.controller,
    required this.showJump,
    required this.onJumpTap,
    this.bottomPadding = 96.0,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView(
          reverse: true,
          controller: controller,
          padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPadding),
          children: children,
        ),
        if (showJump)
          Positioned(
            right: 12,
            bottom: 82,
            child: ScrollToBottomButton(onTap: onJumpTap),
          ),
      ],
    );
  }
}


