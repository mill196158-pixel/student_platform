import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../common/keyboard_dismiss_scope.dart';
import '../../../models/assignment.dart';

typedef AssignmentFormResult = (
  String title,
  String description,
  String? link,
  String? due,
  List<Map<String, String>> attachments,
);

Future<AssignmentFormResult?> showAssignmentFormDialog(
  BuildContext context, {
  Assignment? initial,
}) {
  return showModalBottomSheet<AssignmentFormResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AssignmentFormSheet(initial: initial),
  );
}

class _AssignmentFormSheet extends StatefulWidget {
  final Assignment? initial;
  const _AssignmentFormSheet({this.initial});

  @override
  State<_AssignmentFormSheet> createState() => _AssignmentFormSheetState();
}

class _AssignmentFormSheetState extends State<_AssignmentFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _desc;
  late final TextEditingController _link;
  late final List<Map<String, String>> _files;
  String? _due;
  bool _showLink = false;
  bool _pickingFile = false;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _title = TextEditingController(text: initial?.title ?? '');
    _desc = TextEditingController(text: initial?.description ?? '');
    _link = TextEditingController(text: initial?.link ?? '');
    _due = (initial?.due ?? '').trim().isEmpty ? null : initial!.due!.trim();
    _files = <Map<String, String>>[...?initial?.attachments];
    _showLink = (_link.text).trim().isNotEmpty;
    _title.addListener(_onChanged);
    _desc.addListener(_onChanged);
    _link.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    KeyboardDismissScope.unfocus(context);
    final now = DateTime.now();
    final initial = _parseDue(_due) ?? now;
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      initialDate: initial.isBefore(DateTime(now.year - 1)) ? now : initial,
      helpText: 'Срок сдачи',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
    );
    if (picked == null || !mounted) return;
    setState(() => _due = _fmtDue(picked));
  }

  void _setQuickDue(int daysFromNow) {
    final d = DateTime.now().add(Duration(days: daysFromNow));
    setState(() => _due = _fmtDue(d));
  }

  Future<void> _pickAttachments() async {
    if (_pickingFile) return;
    KeyboardDismissScope.unfocus(context);
    setState(() => _pickingFile = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty || !mounted) return;
      for (final file in result.files) {
        final name = (file.name).trim();
        final path = (file.path ?? '').trim();
        if (name.isEmpty) continue;
        final exists = _files.any(
          (f) => (f['name'] ?? '') == name && (f['path'] ?? '') == path,
        );
        if (exists) continue;
        _files.add({'name': name, if (path.isNotEmpty) 'path': path});
      }
      setState(() {});
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    KeyboardDismissScope.unfocus(context);
    HapticFeedback.lightImpact();
    final link = _link.text.trim();
    Navigator.pop(context, (
      _title.text.trim(),
      _desc.text.trim(),
      link.isEmpty ? null : link,
      (_due ?? '').trim().isEmpty ? null : _due!.trim(),
      List<Map<String, String>>.from(_files),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.92;
    final titleLen = _title.text.trim().length;
    final canSubmit =
        _title.text.trim().isNotEmpty && _desc.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
          child: SizedBox(
            height: maxHeight,
            child: Material(
              color: cs.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Expanded(
                    child: KeyboardDismissScope(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: Container(
                                  width: 42,
                                  height: 4,
                                  margin: const EdgeInsets.only(bottom: 14),
                                  decoration: BoxDecoration(
                                    color: cs.outlineVariant,
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                ),
                              ),
                              _HeroHeader(isEditing: _isEditing),
                              const SizedBox(height: 20),
                              _SectionLabel(
                                icon: Icons.edit_note_rounded,
                                label: 'Суть задания',
                              ),
                              const SizedBox(height: 10),
                              TextFormField(
                                controller: _title,
                                autofocus: !_isEditing,
                                textInputAction: TextInputAction.next,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                                decoration: _fieldDecoration(
                                  label: 'Название',
                                  hint: 'Например: Практика по интегралам',
                                  icon: Icons.title_rounded,
                                  suffix: titleLen > 0
                                      ? Text(
                                          '$titleLen',
                                          style: TextStyle(
                                            color: cs.onSurfaceVariant,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        )
                                      : null,
                                ),
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                        ? 'Добавь название задания'
                                        : null,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _desc,
                                minLines: 4,
                                maxLines: 8,
                                textInputAction: TextInputAction.newline,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                style: const TextStyle(color: Colors.black87),
                                decoration: _fieldDecoration(
                                  label: 'Что сделать',
                                  hint:
                                      'Опиши задачу, формат сдачи и важные условия',
                                  icon: Icons.notes_rounded,
                                  alignLabelWithHint: true,
                                ),
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                        ? 'Опиши, что нужно сделать'
                                        : null,
                              ),
                              const SizedBox(height: 20),
                              _SectionLabel(
                                icon: Icons.event_available_rounded,
                                label: 'Срок',
                                trailing: _due == null
                                    ? 'Необязательно'
                                    : 'Выбран: $_due',
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _QuickChip(
                                    label: 'Завтра',
                                    selected: _isDueInDays(1),
                                    onTap: () => _setQuickDue(1),
                                  ),
                                  _QuickChip(
                                    label: '+3 дня',
                                    selected: _isDueInDays(3),
                                    onTap: () => _setQuickDue(3),
                                  ),
                                  _QuickChip(
                                    label: 'Через неделю',
                                    selected: _isDueInDays(7),
                                    onTap: () => _setQuickDue(7),
                                  ),
                                  _QuickChip(
                                    label: 'Календарь',
                                    icon: Icons.calendar_month_rounded,
                                    selected: _due != null &&
                                        !_isDueInDays(1) &&
                                        !_isDueInDays(3) &&
                                        !_isDueInDays(7),
                                    onTap: _pickDueDate,
                                  ),
                                  if (_due != null)
                                    _QuickChip(
                                      label: 'Сбросить',
                                      icon: Icons.close_rounded,
                                      selected: false,
                                      tone: _ChipTone.muted,
                                      onTap: () => setState(() => _due = null),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              _SectionLabel(
                                icon: Icons.attachment_rounded,
                                label: 'Материалы',
                                trailing: 'Ссылка и файлы',
                              ),
                              const SizedBox(height: 10),
                              if (!_showLink)
                                _SoftActionTile(
                                  icon: Icons.link_rounded,
                                  title: 'Добавить ссылку',
                                  subtitle: 'Google Drive, GitHub, LMS…',
                                  onTap: () => setState(() => _showLink = true),
                                )
                              else ...[
                                TextFormField(
                                  controller: _link,
                                  keyboardType: TextInputType.url,
                                  textInputAction: TextInputAction.done,
                                  style: const TextStyle(color: Colors.black87),
                                  decoration: _fieldDecoration(
                                    label: 'Ссылка',
                                    hint: 'https://…',
                                    icon: Icons.link_rounded,
                                    suffix: IconButton(
                                      tooltip: 'Убрать ссылку',
                                      onPressed: () {
                                        _link.clear();
                                        setState(() => _showLink = false);
                                      },
                                      icon: const Icon(Icons.close_rounded,
                                          size: 20),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              const SizedBox(height: 8),
                              _SoftActionTile(
                                icon: Icons.upload_file_rounded,
                                title: _pickingFile
                                    ? 'Выбираем файлы…'
                                    : 'Прикрепить файлы',
                                subtitle: _files.isEmpty
                                    ? 'PDF, фото, документы — по желанию'
                                    : 'Файлов: ${_files.length}',
                                busy: _pickingFile,
                                onTap: _pickingFile ? null : _pickAttachments,
                              ),
                              if (_files.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                for (var i = 0; i < _files.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: _AttachmentTile(
                                      name: _files[i]['name'] ?? 'Файл',
                                      path: _files[i]['path'] ?? '',
                                      onRemove: () =>
                                          setState(() => _files.removeAt(i)),
                                    ),
                                  ),
                              ],
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: cs.primary.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: cs.primary.withValues(alpha: 0.10),
                                  ),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.tips_and_updates_outlined,
                                        size: 18, color: cs.primary),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _isEditing
                                            ? 'После сохранения карточка обновится в чате и на вкладке «Задания».'
                                            : 'Чтобы задание появилось у всех, нужны 2 голоса одногруппников.',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      border: Border(
                        top: BorderSide(
                          color: Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: const Text('Отмена'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            onPressed: canSubmit ? _submit : null,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 48),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            icon: Icon(
                              _isEditing
                                  ? Icons.save_rounded
                                  : Icons.add_task_rounded,
                            ),
                            label: Text(
                              _isEditing ? 'Сохранить' : 'Добавить задание',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isDueInDays(int days) {
    final target = _fmtDue(DateTime.now().add(Duration(days: days)));
    return _due == target;
  }

  static String _fmtDue(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

  static DateTime? _parseDue(String? due) {
    if (due == null || due.trim().isEmpty) return null;
    final parts = due.trim().split('.');
    if (parts.length != 2) return null;
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (day == null || month == null) return null;
    final now = DateTime.now();
    return DateTime(now.year, month, day);
  }

  InputDecoration _fieldDecoration({
    required String label,
    required String hint,
    required IconData icon,
    Widget? suffix,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: alignLabelWithHint,
      prefixIcon: Icon(icon),
      suffixIcon: suffix == null
          ? null
          : (suffix is IconButton
              ? suffix
              : Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    widthFactor: 1,
                    child: suffix,
                  ),
                )),
      filled: true,
      fillColor: const Color(0xFFF6F7FB),
      labelStyle: const TextStyle(color: Colors.black54),
      floatingLabelStyle: const TextStyle(
        color: Colors.black87,
        fontWeight: FontWeight.w700,
      ),
      hintStyle: TextStyle(color: Colors.black.withValues(alpha: 0.35)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE1E5EF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.black87, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE53935)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.4),
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  final bool isEditing;
  const _HeroHeader({required this.isEditing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  cs.primary.withValues(alpha: 0.14),
                  cs.primaryContainer.withValues(alpha: 0.55),
                  const Color(0xFFF6F7FB),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Positioned(
            right: -24,
            top: -28,
            child: _GlowBlob(
              diameter: 110,
              color: cs.primary.withValues(alpha: 0.16),
            ),
          ),
          Positioned(
            left: -18,
            bottom: -34,
            child: _GlowBlob(
              diameter: 96,
              color: Colors.white.withValues(alpha: 0.65),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    isEditing ? Icons.edit_note_rounded : Icons.assignment_add,
                    color: cs.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEditing ? 'Редактировать задание' : 'Новое задание',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isEditing
                            ? 'Обнови формулировку, срок и материалы'
                            : 'Чтобы появилось у всех — нужны 2 голоса',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.black.withValues(alpha: 0.62),
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  final double diameter;
  final Color color;
  const _GlowBlob({required this.diameter, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  const _SectionLabel({
    required this.icon,
    required this.label,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: Colors.black87,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.black45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

enum _ChipTone { accent, muted }

class _QuickChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final _ChipTone tone;

  const _QuickChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.tone = _ChipTone.accent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMuted = tone == _ChipTone.muted;
    final bg = selected
        ? cs.primary
        : (isMuted
            ? Colors.black.withValues(alpha: 0.05)
            : const Color(0xFFF6F7FB));
    final fg =
        selected ? cs.onPrimary : (isMuted ? Colors.black54 : Colors.black87);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? Colors.transparent : const Color(0xFFE1E5EF),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoftActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool busy;

  const _SoftActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: const Color(0xFFF6F7FB),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: const Border.fromBorderSide(
              BorderSide(color: Color(0xFFE1E5EF)),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.primary,
                        ),
                      )
                    : Icon(icon, color: cs.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.add_rounded, color: cs.primary.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  final String name;
  final String path;
  final VoidCallback onRemove;

  const _AttachmentTile({
    required this.name,
    required this.path,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isImage = _looksLikeImage(name) || _looksLikeImage(path);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E5EF)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined,
              size: 18,
              color: cs.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                if (path.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.black45,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Удалить',
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  static bool _looksLikeImage(String value) {
    final lower = value.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic');
  }
}
