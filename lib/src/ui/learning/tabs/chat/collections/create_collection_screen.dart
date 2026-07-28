import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../common/keyboard_dismiss_scope.dart';
import '../data/chat_group_actions_repository.dart';

/// High-quality «Скинуться» form matching the New Assignment design language.
class CreateCollectionScreen extends StatefulWidget {
  const CreateCollectionScreen({
    super.key,
    this.repository,
  });

  final ChatGroupActionsRepository? repository;

  @override
  State<CreateCollectionScreen> createState() => _CreateCollectionScreenState();
}

enum _AmountMode { none, perPerson, total }

class _CreateCollectionScreenState extends State<CreateCollectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _paymentCtrl = TextEditingController();
  final _instructionsCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();

  DateTime? _deadline;
  _AmountMode _amountMode = _AmountMode.none;
  bool _showLink = false;
  bool _pickingFile = false;
  bool _saving = false;
  String? _error;
  final List<Map<String, String>> _files = [];

  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository();

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(_onChanged);
    _descCtrl.addListener(_onChanged);
    _purposeCtrl.addListener(_onChanged);
    _amountCtrl.addListener(_onChanged);
    _paymentCtrl.addListener(_onChanged);
    _instructionsCtrl.addListener(_onChanged);
    _linkCtrl.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _purposeCtrl.dispose();
    _amountCtrl.dispose();
    _paymentCtrl.dispose();
    _instructionsCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  String get _amountModeRpc {
    switch (_amountMode) {
      case _AmountMode.none:
        return 'none';
      case _AmountMode.perPerson:
        return 'per_person';
      case _AmountMode.total:
        return 'total';
    }
  }

  bool get _canSubmit {
    if (_saving) return false;
    if (_titleCtrl.text.trim().isEmpty) return false;
    if (_amountMode == _AmountMode.none) return true;
    final amount =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    return amount != null && amount > 0;
  }

  Future<void> _pickDeadline() async {
    KeyboardDismissScope.unfocus(context);
    final now = DateTime.now();
    final initial = _deadline ?? now;
    final picked = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
      initialDate: initial.isBefore(now) ? now : initial,
      helpText: 'Скинуться до',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _deadline ?? now.add(const Duration(hours: 2)),
      ),
      helpText: 'Скинуться до',
      cancelText: 'Отмена',
      confirmText: 'Готово',
    );
    if (time == null || !mounted) return;
    setState(() {
      _deadline = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
      );
    });
  }

  void _setQuickDeadline(int daysFromNow) {
    final now = DateTime.now();
    final base = now.add(Duration(days: daysFromNow));
    setState(() {
      _deadline = DateTime(base.year, base.month, base.day, 23, 59);
    });
  }

  bool _isDeadlineInDays(int days) {
    final d = _deadline;
    if (d == null) return false;
    final target = DateTime.now().add(Duration(days: days));
    return d.year == target.year &&
        d.month == target.month &&
        d.day == target.day;
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

  void _setAmountMode(_AmountMode mode) {
    setState(() {
      _amountMode = mode;
      if (mode == _AmountMode.none) {
        _amountCtrl.clear();
      }
    });
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_canSubmit) return;
    KeyboardDismissScope.unfocus(context);
    HapticFeedback.lightImpact();

    final amount =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    // Optional link / attachments are stored locally for a future repository
    // pass-through; payment instructions stay the source of truth for now.
    final link = _linkCtrl.text.trim();
    var instructions = _instructionsCtrl.text.trim();
    if (link.isNotEmpty) {
      instructions = instructions.isEmpty
          ? 'Ссылка: $link'
          : '$instructions\n\nСсылка: $link';
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _repo.createCollection(
        title: _titleCtrl.text.trim(),
        purpose: _purposeCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        deadlineAt: _deadline,
        amountMode: _amountModeRpc,
        amountOptional: _amountMode == _AmountMode.perPerson ? amount : null,
        amountTotal: _amountMode == _AmountMode.total ? amount : null,
        instructions: instructions,
        paymentDetails: _paymentCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('«Скинуться» опубликовано в чат')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось создать «Скинуться»');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать «Скинуться»')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmtDeadline(DateTime? dt) {
    if (dt == null) return 'Не задан';
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final titleLen = _titleCtrl.text.trim().length;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: KeyboardDismissScope(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: 'Назад',
                            onPressed: _saving
                                ? null
                                : () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                        const _HeroHeader(),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.edit_note_rounded,
                          label: 'О сборе',
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _titleCtrl,
                          autofocus: true,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                          decoration: _fieldDecoration(
                            label: 'Название',
                            hint: 'Например: На подарок старосте',
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
                          validator: (value) => (value ?? '').trim().isEmpty
                              ? 'Добавьте название сбора'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _descCtrl,
                          minLines: 2,
                          maxLines: 4,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: Colors.black87),
                          decoration: _fieldDecoration(
                            label: 'Краткое описание',
                            hint: 'Что собираем и зачем — в двух словах',
                            icon: Icons.notes_rounded,
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _purposeCtrl,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: Colors.black87),
                          decoration: _fieldDecoration(
                            label: 'Цель',
                            hint: 'Например: день рождения, экскурсия…',
                            icon: Icons.flag_outlined,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.payments_outlined,
                          label: 'Сумма',
                          trailing: 'Один вариант',
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _QuickChip(
                              label: 'Без суммы',
                              selected: _amountMode == _AmountMode.none,
                              onTap: () => _setAmountMode(_AmountMode.none),
                            ),
                            _QuickChip(
                              label: 'С человека',
                              icon: Icons.person_outline_rounded,
                              selected: _amountMode == _AmountMode.perPerson,
                              onTap: () =>
                                  _setAmountMode(_AmountMode.perPerson),
                            ),
                            _QuickChip(
                              label: 'Общая',
                              icon: Icons.groups_2_outlined,
                              selected: _amountMode == _AmountMode.total,
                              onTap: () => _setAmountMode(_AmountMode.total),
                            ),
                          ],
                        ),
                        if (_amountMode != _AmountMode.none) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textInputAction: TextInputAction.next,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                            decoration: _fieldDecoration(
                              label: _amountMode == _AmountMode.perPerson
                                  ? 'Сумма с человека'
                                  : 'Общая сумма',
                              hint: '₽',
                              icon: Icons.currency_ruble_rounded,
                            ),
                            validator: (value) {
                              if (_amountMode == _AmountMode.none) {
                                return null;
                              }
                              final amount = double.tryParse(
                                (value ?? '').trim().replaceAll(',', '.'),
                              );
                              if (amount == null || amount <= 0) {
                                return 'Укажите сумму больше 0';
                              }
                              return null;
                            },
                          ),
                        ],
                        const SizedBox(height: 20),
                        _SectionLabel(
                          icon: Icons.event_available_rounded,
                          label: 'Срок',
                          trailing: _deadline == null
                              ? 'Необязательно'
                              : 'До ${_fmtDeadline(_deadline)}',
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _QuickChip(
                              label: 'Завтра',
                              selected: _isDeadlineInDays(1),
                              onTap: () => _setQuickDeadline(1),
                            ),
                            _QuickChip(
                              label: '+3 дня',
                              selected: _isDeadlineInDays(3),
                              onTap: () => _setQuickDeadline(3),
                            ),
                            _QuickChip(
                              label: 'Через неделю',
                              selected: _isDeadlineInDays(7),
                              onTap: () => _setQuickDeadline(7),
                            ),
                            _QuickChip(
                              label: 'Календарь',
                              icon: Icons.calendar_month_rounded,
                              selected: _deadline != null &&
                                  !_isDeadlineInDays(1) &&
                                  !_isDeadlineInDays(3) &&
                                  !_isDeadlineInDays(7),
                              onTap: _pickDeadline,
                            ),
                            if (_deadline != null)
                              _QuickChip(
                                label: 'Сбросить',
                                icon: Icons.close_rounded,
                                selected: false,
                                tone: _ChipTone.muted,
                                onTap: () => setState(() => _deadline = null),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.account_balance_wallet_outlined,
                          label: 'Как перевести',
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _paymentCtrl,
                          minLines: 2,
                          maxLines: 4,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: Colors.black87),
                          decoration: _fieldDecoration(
                            label: 'Реквизиты',
                            hint: 'Карта, СБП, комментарий к переводу',
                            icon: Icons.credit_card_outlined,
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _instructionsCtrl,
                          minLines: 2,
                          maxLines: 4,
                          textInputAction: TextInputAction.done,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(color: Colors.black87),
                          decoration: _fieldDecoration(
                            label: 'Инструкции',
                            hint: 'Когда скидываться, кому писать…',
                            icon: Icons.checklist_rounded,
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.attachment_rounded,
                          label: 'Материалы',
                          trailing: 'По желанию',
                        ),
                        const SizedBox(height: 10),
                        if (!_showLink)
                          _SoftActionTile(
                            icon: Icons.link_rounded,
                            title: 'Добавить ссылку',
                            subtitle: 'Форма оплаты, чат, таблица…',
                            onTap: () => setState(() => _showLink = true),
                          )
                        else ...[
                          TextFormField(
                            controller: _linkCtrl,
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
                                  _linkCtrl.clear();
                                  setState(() => _showLink = false);
                                },
                                icon: const Icon(Icons.close_rounded, size: 20),
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
                              : 'Прикрепить файл или фото',
                          subtitle: _files.isEmpty
                              ? 'Квитанция, скрин, документ — по желанию'
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
                        const SizedBox(height: 12),
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
                              Icon(Icons.lock_outline_rounded,
                                  size: 18, color: cs.primary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Приложение не принимает платежи. Переводы '
                                  'идут напрямую организатору. Участие и '
                                  'поступление подтверждаются вручную — '
                                  'это приватный учёт внутри группы.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.error),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + viewInsets.bottom),
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
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
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
                      onPressed: _canSubmit ? _submit : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.volunteer_activism_rounded),
                      label: Text(
                        _saving ? 'Публикуем…' : 'Создать сбор',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
  const _HeroHeader();

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
                    Icons.volunteer_activism_rounded,
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
                        'Сбор денег',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Сбор внутри группы — переводы вне приложения',
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
