import 'package:flutter/material.dart';

import '../../../shared/widgets/publication_status_badge.dart';
import 'visual_editor_shell.dart';

/// Row model for the shared visual editor list panel.
class VisualEditorListItem {
  const VisualEditorListItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.isDemo = false,
    this.leading,
    this.statusLabel,
    this.trailing,
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool isDemo;
  final Widget? leading;
  final String? statusLabel;
  final Widget? trailing;
}

/// Left-panel list with publication tabs, optional demo filter, and reorder.
class VisualEditorListPanel extends StatelessWidget {
  const VisualEditorListPanel({
    required this.tab,
    required this.tabCounts,
    required this.items,
    required this.selectedId,
    required this.onTabChanged,
    required this.onSelected,
    this.panelTitle = 'Элементы',
    this.onMove,
    this.onCreate,
    this.showDemoOnly = false,
    this.onDemoFilterChanged,
    super.key,
  });

  final String panelTitle;
  final VisualEditorListTab tab;
  final VisualEditorTabCounts tabCounts;
  final List<VisualEditorListItem> items;
  final String? selectedId;
  final ValueChanged<VisualEditorListTab> onTabChanged;
  final ValueChanged<String> onSelected;
  final ValueChanged<int>? onMove;
  final VoidCallback? onCreate;
  final bool showDemoOnly;
  final ValueChanged<bool>? onDemoFilterChanged;

  int get _selectedIndex => items.indexWhere((item) => item.id == selectedId);

  bool get _canReorder => onMove != null && tab != VisualEditorListTab.archived;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    panelTitle,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_canReorder || onCreate != null)
                  OverflowBar(
                    spacing: 0,
                    overflowSpacing: 0,
                    children: [
                      if (_canReorder) ...[
                        IconButton(
                          tooltip: 'Выше',
                          visualDensity: VisualDensity.compact,
                          onPressed: _selectedIndex > 0
                              ? () => onMove!.call(-1)
                              : null,
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                        IconButton(
                          tooltip: 'Ниже',
                          visualDensity: VisualDensity.compact,
                          onPressed:
                              _selectedIndex >= 0 &&
                                  _selectedIndex < items.length - 1
                              ? () => onMove!.call(1)
                              : null,
                          icon: const Icon(Icons.arrow_downward_rounded),
                        ),
                      ],
                      if (onCreate != null)
                        IconButton.filledTonal(
                          tooltip: 'Создать черновик',
                          visualDensity: VisualDensity.compact,
                          onPressed: onCreate,
                          icon: const Icon(Icons.add_rounded),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<VisualEditorListTab>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: VisualEditorListTab.published,
                  label: Text(
                    '${VisualEditorListTab.published.labelRu} (${tabCounts.published})',
                  ),
                  icon: const Icon(Icons.public_rounded, size: 16),
                ),
                ButtonSegment(
                  value: VisualEditorListTab.drafts,
                  label: Text(
                    '${VisualEditorListTab.drafts.labelRu} (${tabCounts.drafts})',
                  ),
                  icon: const Icon(Icons.edit_note_rounded, size: 16),
                ),
                ButtonSegment(
                  value: VisualEditorListTab.archived,
                  label: Text(
                    '${VisualEditorListTab.archived.labelRu} (${tabCounts.archived})',
                  ),
                  icon: const Icon(Icons.inventory_2_outlined, size: 16),
                ),
              ],
              selected: {tab},
              onSelectionChanged: (value) {
                if (value.isNotEmpty) onTabChanged(value.first);
              },
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            if (onDemoFilterChanged != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: const Text('Демо'),
                  selected: showDemoOnly,
                  onSelected: onDemoFilterChanged,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              tab.labelRu,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF5C6370),
              ),
            ),
            const Divider(height: 20),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text(tab.emptyMessageRu))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final isSelected = item.id == selectedId;
                        return Material(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                          child: ListTile(
                            selected: isSelected,
                            isThreeLine:
                                item.subtitle != null ||
                                item.statusLabel != null ||
                                item.isDemo,
                            onTap: () => onSelected(item.id),
                            leading: item.leading,
                            title: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: _ListItemSubtitle(item: item),
                            trailing: item.trailing,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListItemSubtitle extends StatelessWidget {
  const _ListItemSubtitle({required this.item});

  final VisualEditorListItem item;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (item.subtitle != null && item.subtitle!.isNotEmpty) {
      children.add(
        Text(item.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    if (item.isDemo || item.statusLabel != null) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 4));
      }
      children.add(
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (item.isDemo) const _DemoBadge(),
            if (item.statusLabel != null)
              PublicationStatusBadge(status: item.statusLabel!),
          ],
        ),
      );
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x1F6656D9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF6656D9), width: 1.2),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          'Демо',
          style: TextStyle(
            color: Color(0xFF4A3FA8),
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
