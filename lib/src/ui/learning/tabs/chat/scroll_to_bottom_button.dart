import 'package:flutter/material.dart';

class ScrollToBottomButton extends StatelessWidget {
  final VoidCallback onTap;
  const ScrollToBottomButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.primary;
    return Material(
      color: bg,
      elevation: 2,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
