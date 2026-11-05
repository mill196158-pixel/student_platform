import 'package:flutter/material.dart';

class SubjectFilterOption<T> {
  const SubjectFilterOption(this.value, this.label);
  final T value;
  final String label;
}

class SemesterSubjectSelection<T> {
  const SemesterSubjectSelection(this.semester, this.filter);
  final int? semester;
  final T filter;
}

Future<SemesterSubjectSelection<T>?> showSemesterSubjectsPicker<T>(
  BuildContext context, {
  required List<int> semesters,
  required int? semester,
  required int? currentSemester,
  required List<SubjectFilterOption<T>> filters,
  required T selectedFilter,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<SemesterSubjectSelection<T>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => SemesterSubjectsPicker<T>(
      semesters: semesters,
      semester: semester,
      currentSemester: currentSemester,
      filters: filters,
      selectedFilter: selectedFilter,
      onClose: () => Navigator.of(sheetContext).pop(),
      onApply: (selection) => Navigator.of(sheetContext).pop(selection),
    ),
  );
}

/// Presentation-only draft selection; callbacks never write academic context.
class SemesterSubjectsPicker<T> extends StatefulWidget {
  const SemesterSubjectsPicker({
    super.key,
    required this.semesters,
    required this.semester,
    required this.currentSemester,
    required this.filters,
    required this.selectedFilter,
    required this.onApply,
    required this.onClose,
  });

  final List<int> semesters;
  final int? semester;
  final int? currentSemester;
  final List<SubjectFilterOption<T>> filters;
  final T selectedFilter;
  final ValueChanged<SemesterSubjectSelection<T>> onApply;
  final VoidCallback onClose;

  @override
  State<SemesterSubjectsPicker<T>> createState() =>
      _SemesterSubjectsPickerState<T>();
}

class _SemesterSubjectsPickerState<T> extends State<SemesterSubjectsPicker<T>> {
  late int? _semester = widget.semester;
  late T _filter = widget.selectedFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .82),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 12, 16),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Предметы семестра',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Text('Выберите семестр и тип контроля',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ])),
                IconButton(
                    tooltip: 'Закрыть без применения',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded)),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Семестр', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 12),
                      if (widget.semesters.isEmpty)
                        Text('Семестры пока не указаны',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant))
                      else
                        LayoutBuilder(builder: (context, constraints) {
                          final scale =
                              MediaQuery.textScalerOf(context).scale(12) / 12;
                          final columns = (constraints.maxWidth / (72 * scale))
                              .floor()
                              .clamp(1, widget.semesters.length.clamp(1, 6));
                          final width =
                              (constraints.maxWidth - 8 * (columns - 1)) /
                                  columns;
                          return Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final value in widget.semesters)
                              SizedBox(
                                  width: width,
                                  child: _SemesterOption(
                                    value: value,
                                    selected: _semester == value,
                                    current: widget.currentSemester == value,
                                    onTap: () =>
                                        setState(() => _semester = value),
                                  )),
                          ]);
                        }),
                      const SizedBox(height: 24),
                      Text('Тип контроля', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final option in widget.filters)
                          ChoiceChip(
                            key: ValueKey('subject-filter-${option.value}'),
                            label: Text(option.label),
                            selected: _filter == option.value,
                            onSelected: (_) =>
                                setState(() => _filter = option.value),
                            showCheckmark: true,
                            selectedColor: cs.primaryContainer,
                            backgroundColor: cs.surface,
                            labelStyle: theme.textTheme.labelLarge?.copyWith(
                                color: _filter == option.value
                                    ? cs.onPrimaryContainer
                                    : cs.onSurface),
                            checkmarkColor: cs.onPrimaryContainer,
                            side: BorderSide(
                                color: _filter == option.value
                                    ? cs.primary.withValues(alpha: .4)
                                    : cs.outlineVariant),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 10),
                          ),
                      ]),
                    ]),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: cs.outlineVariant))),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: FilledButton(
                  onPressed: () => widget
                      .onApply(SemesterSubjectSelection(_semester, _filter)),
                  child: const Text('Показать предметы'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SemesterOption extends StatelessWidget {
  const _SemesterOption(
      {required this.value,
      required this.selected,
      required this.current,
      required this.onTap});
  final int value;
  final bool selected;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = selected ? cs.onPrimary : cs.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Семестр $value${current ? ', текущий' : ''}',
      child: Material(
        color: selected ? cs.primary : cs.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: selected ? cs.primary : cs.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ExcludeSemantics(
                        child: Text('$value',
                            style: theme.textTheme.bodyLarge?.copyWith(
                                color: fg, fontWeight: FontWeight.w600))),
                    const SizedBox(height: 3),
                    if (current)
                      ExcludeSemantics(
                          child: Text('текущий',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: selected
                                      ? cs.onPrimary
                                      : cs.onSurfaceVariant)))
                    else
                      Icon(
                          selected ? Icons.check_rounded : Icons.remove_rounded,
                          size: 16,
                          color: selected ? fg : Colors.transparent),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
