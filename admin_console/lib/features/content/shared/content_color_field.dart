import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'content_color_utils.dart';

/// Single hex color field with palette swatches and optional advanced hex input.
class ContentColorField extends StatefulWidget {
  const ContentColorField({
    required this.label,
    required this.hexValue,
    required this.onChanged,
    this.enabled = true,
    this.contrastAgainst,
    super.key,
  });

  final String label;
  final String hexValue;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final Color? contrastAgainst;

  @override
  State<ContentColorField> createState() => _ContentColorFieldState();
}

class _ContentColorFieldState extends State<ContentColorField> {
  bool _advancedExpanded = false;
  late TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hexController = TextEditingController(text: widget.hexValue);
  }

  @override
  void didUpdateWidget(covariant ContentColorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hexValue != widget.hexValue &&
        _hexController.text != widget.hexValue) {
      _hexController.text = widget.hexValue;
    }
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Color get _currentColor =>
      parseContentHexColor(widget.hexValue) ?? const Color(0xFFFFFBFF);

  void _selectColor(Color color) {
    if (!widget.enabled) return;
    final hex = formatContentHexColor(color);
    _hexController.text = hex;
    widget.onChanged(hex);
    setState(() {});
  }

  void _applyHexInput(String raw) {
    final parsed = parseContentHexColor(raw);
    if (parsed == null) return;
    widget.onChanged(formatContentHexColor(parsed));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final contrastTarget = widget.contrastAgainst;
    final warning = contrastTarget == null
        ? null
        : contentContrastWarning(
            foreground: contrastTarget.computeLuminance() > 0.5
                ? Colors.black
                : Colors.white,
            background: _currentColor,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _currentColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFD8DCE8)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.hexValue,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Color(0xFF5C6370),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final swatch in kContentAppColorSwatches)
              _SwatchChip(
                color: swatch,
                selected:
                    formatContentHexColor(swatch) ==
                    formatContentHexColor(_currentColor),
                enabled: widget.enabled,
                onTap: () => _selectColor(swatch),
              ),
          ],
        ),
        if (warning != null) ...[
          const SizedBox(height: 6),
          Text(
            warning,
            style: const TextStyle(color: Color(0xFFB3261E), fontSize: 12),
          ),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Дополнительно', style: TextStyle(fontSize: 13)),
          initiallyExpanded: _advancedExpanded,
          onExpansionChanged: (value) =>
              setState(() => _advancedExpanded = value),
          children: [
            TextField(
              controller: _hexController,
              enabled: widget.enabled,
              decoration: const InputDecoration(
                labelText: 'HEX',
                hintText: '#RRGGBB',
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[#0-9A-Fa-f]')),
              ],
              onSubmitted: _applyHexInput,
              onChanged: (value) {
                if (RegExp(r'^#?[0-9A-Fa-f]{6}$').hasMatch(value.trim())) {
                  _applyHexInput(value);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _SwatchChip extends StatelessWidget {
  const _SwatchChip({
    required this.color,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : const Color(0xFFD8DCE8),
              width: selected ? 2 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// Two-color gradient field with direction and live preview strip.
class ContentGradientField extends StatelessWidget {
  const ContentGradientField({
    required this.colorA,
    required this.colorB,
    required this.directionDegrees,
    required this.onColorAChanged,
    required this.onColorBChanged,
    required this.onDirectionChanged,
    this.enabled = true,
    super.key,
  });

  final String colorA;
  final String colorB;
  final int directionDegrees;
  final ValueChanged<String> onColorAChanged;
  final ValueChanged<String> onColorBChanged;
  final ValueChanged<int> onDirectionChanged;
  final bool enabled;

  static const directionOptions = <int, String>{
    0: '→',
    45: '↘',
    90: '↓',
    135: '↙',
  };

  @override
  Widget build(BuildContext context) {
    final gradient = contentLinearGradientFromHex(
      colorA: colorA,
      colorB: colorB,
      directionDegrees: directionDegrees,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Градиент', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Container(
          height: 36,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD8DCE8)),
          ),
        ),
        const SizedBox(height: 12),
        ContentColorField(
          label: 'Цвет 1',
          hexValue: colorA,
          enabled: enabled,
          contrastAgainst: Colors.black,
          onChanged: onColorAChanged,
        ),
        const SizedBox(height: 8),
        ContentColorField(
          label: 'Цвет 2',
          hexValue: colorB,
          enabled: enabled,
          contrastAgainst: Colors.black,
          onChanged: onColorBChanged,
        ),
        const SizedBox(height: 8),
        Text('Направление', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in directionOptions.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: directionDegrees == entry.key,
                onSelected: !enabled
                    ? null
                    : (_) => onDirectionChanged(entry.key),
              ),
          ],
        ),
      ],
    );
  }
}
