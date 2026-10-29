import 'package:flutter/material.dart';

/// Mount only on first visit, then retain the same subtree while offstage.
class VisitedTab extends StatefulWidget {
  const VisitedTab({super.key, required this.active, required this.builder});
  final bool active;
  final WidgetBuilder builder;

  @override
  State<VisitedTab> createState() => _VisitedTabState();
}

class _VisitedTabState extends State<VisitedTab> {
  bool _visited = false;

  @override
  Widget build(BuildContext context) {
    _visited = _visited || widget.active;
    return Offstage(
      offstage: !widget.active,
      child: TickerMode(
        enabled: widget.active,
        child: _visited ? widget.builder(context) : const SizedBox.shrink(),
      ),
    );
  }
}
