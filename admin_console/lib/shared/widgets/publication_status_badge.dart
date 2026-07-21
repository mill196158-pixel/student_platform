import 'package:flutter/material.dart';

class PublicationStatusBadge extends StatelessWidget {
  const PublicationStatusBadge({required this.status, super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final isPublished = status == 'Опубликован';
    final color = isPublished
        ? const Color(0xFF3C8B65)
        : const Color(0xFF9B6A2F);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          status,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
