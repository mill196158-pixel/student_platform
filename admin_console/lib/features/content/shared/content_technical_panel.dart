import 'package:flutter/material.dart';

/// Collapsible «Дополнительно» panel for legacy / technical editor fields.
class ContentTechnicalPanel extends StatelessWidget {
  const ContentTechnicalPanel({
    required this.children,
    this.initiallyExpanded = false,
    super.key,
  });

  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('Дополнительно'),
      initiallyExpanded: initiallyExpanded,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}
