import 'package:flutter/material.dart';

/// Home page placement slots (payload `home_slot`, not placement surface).
enum ContentHomeSlot {
  afterNews('after_news', 'После новостей'),
  afterDaySummary('after_day_summary', 'После сводки дня'),
  afterAssignments('after_assignments', 'После ближайших дел'),
  beforeBottomInfo('before_bottom_info', 'Перед нижним блоком'),
  endOfPage('end_of_page', 'В конце страницы');

  const ContentHomeSlot(this.key, this.labelRu);

  final String key;
  final String labelRu;

  static ContentHomeSlot fromKey(String? raw) {
    if (raw == null || raw.isEmpty) return ContentHomeSlot.afterAssignments;
    for (final slot in values) {
      if (slot.key == raw) return slot;
    }
    return ContentHomeSlot.afterAssignments;
  }
}

/// Russian label for a home slot key.
String contentHomeSlotLabelRu(String? key) =>
    ContentHomeSlot.fromKey(key).labelRu;

/// Picker with mini schematic highlighting the selected home section.
class ContentPlacementSlotPicker extends StatelessWidget {
  const ContentPlacementSlotPicker({
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final ContentHomeSlot selected;
  final ValueChanged<ContentHomeSlot> onChanged;
  final bool enabled;

  static const _slotOrder = ContentHomeSlot.values;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Место на главной', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        _HomeSchematic(selected: selected),
        const SizedBox(height: 12),
        ..._slotOrder.map(
          (slot) => RadioListTile<ContentHomeSlot>(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(slot.labelRu),
            value: slot,
            groupValue: selected,
            onChanged: !enabled
                ? null
                : (value) {
                    if (value != null) onChanged(value);
                  },
          ),
        ),
      ],
    );
  }
}

class _HomeSchematic extends StatelessWidget {
  const _HomeSchematic({required this.selected});

  final ContentHomeSlot selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD8DCE8)),
      ),
      child: Column(
        children: [
          _SchematicBlock(label: 'Шапка', highlighted: false),
          _slotDivider(ContentHomeSlot.afterNews),
          _SchematicBlock(
            label: 'Новости',
            highlighted: selected == ContentHomeSlot.afterNews,
          ),
          _slotDivider(ContentHomeSlot.afterDaySummary),
          _SchematicBlock(
            label: 'Сводка дня',
            highlighted: selected == ContentHomeSlot.afterDaySummary,
          ),
          _slotDivider(ContentHomeSlot.afterAssignments),
          _SchematicBlock(
            label: 'Ближайшие дела',
            highlighted: selected == ContentHomeSlot.afterAssignments,
          ),
          _slotDivider(ContentHomeSlot.beforeBottomInfo),
          _SchematicBlock(
            label: 'Promo / контент',
            highlighted:
                selected == ContentHomeSlot.beforeBottomInfo ||
                selected == ContentHomeSlot.endOfPage,
          ),
          if (selected == ContentHomeSlot.endOfPage) ...[
            const SizedBox(height: 4),
            _SchematicBlock(label: 'Нижний блок', highlighted: true),
          ] else
            _SchematicBlock(label: 'Нижний блок', highlighted: false),
        ],
      ),
    );
  }

  Widget _slotDivider(ContentHomeSlot slotAfter) {
    if (selected != slotAfter) {
      return const SizedBox(height: 4);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Container(height: 2, color: const Color(0xFF6656D9))),
          const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: Color(0xFF6656D9),
            ),
          ),
        ],
      ),
    );
  }
}

class _SchematicBlock extends StatelessWidget {
  const _SchematicBlock({required this.label, required this.highlighted});

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xFFE8E0F5) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlighted
              ? const Color(0xFF6656D9)
              : const Color(0xFFE0E3EB),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
          color: highlighted
              ? const Color(0xFF4A3F8C)
              : const Color(0xFF5C6370),
        ),
      ),
    );
  }
}
