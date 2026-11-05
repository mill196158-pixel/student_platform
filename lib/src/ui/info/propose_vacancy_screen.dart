import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'vacancy_submission_service.dart';

/// Student form to propose or resubmit a vacancy after clarification.
///
/// New submissions call `submit_vacancy` (status `submitted`).
/// Clarified drafts use `update_my_vacancy_draft` + `resubmit_my_vacancy`.
class ProposeVacancyScreen extends StatefulWidget {
  const ProposeVacancyScreen({
    super.key,
    this.submissionService,
    this.existingSubmission,
  });

  final VacancySubmissionService? submissionService;
  final MyVacancySubmissionItem? existingSubmission;

  @override
  State<ProposeVacancyScreen> createState() => _ProposeVacancyScreenState();
}

class _ProposeVacancyScreenState extends State<ProposeVacancyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleKey = GlobalKey<FormFieldState<String>>();
  final _summaryKey = GlobalKey<FormFieldState<String>>();
  late final VacancySubmissionService _service =
      widget.submissionService ?? VacancySubmissionService();

  final _titleController = TextEditingController();
  final _companyController = TextEditingController();
  final _summaryController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _requirementsController = TextEditingController();
  final _locationController = TextEditingController();
  final _salaryController = TextEditingController();
  final _urlController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  VacancyEmploymentType? _employmentType;
  VacancyWorkFormat? _workFormat;
  bool _busy = false;
  String? _banner;
  bool _usedLocalFallback = false;
  int? _rowVersion;
  String? _clarificationReason;

  bool get _isEditDraft =>
      widget.existingSubmission != null &&
      widget.existingSubmission!.status == 'draft';

  @override
  void initState() {
    super.initState();
    final existing = widget.existingSubmission;
    if (existing != null) {
      final draft = existing.toDraft();
      _titleController.text = draft.title;
      _companyController.text = draft.companyName;
      _summaryController.text = draft.summary;
      _descriptionController.text = draft.description;
      _requirementsController.text = draft.requirements;
      _locationController.text = draft.location ?? '';
      _salaryController.text = draft.salaryText ?? '';
      _urlController.text = draft.externalUrl ?? '';
      _emailController.text = draft.contacts['email']?.toString() ?? '';
      _phoneController.text = draft.contacts['phone']?.toString() ?? '';
      _employmentType = draft.employmentType;
      _workFormat = draft.workFormat;
      _rowVersion = existing.rowVersion;
      _clarificationReason = existing.rejectionReason;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _companyController.dispose();
    _summaryController.dispose();
    _descriptionController.dispose();
    _requirementsController.dispose();
    _locationController.dispose();
    _salaryController.dispose();
    _urlController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  VacancySubmissionDraft _draftFromFields() {
    final contacts = <String, dynamic>{};
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    if (email.isNotEmpty) contacts['email'] = email;
    if (phone.isNotEmpty) contacts['phone'] = phone;

    return VacancySubmissionDraft(
      title: _titleController.text.trim(),
      companyName: _companyController.text.trim(),
      summary: _summaryController.text.trim(),
      description: _descriptionController.text.trim(),
      requirements: _requirementsController.text.trim(),
      employmentType: _employmentType,
      workFormat: _workFormat,
      location: _locationController.text.trim().isEmpty
          ? null
          : _locationController.text.trim(),
      salaryText: _salaryController.text.trim().isEmpty
          ? null
          : _salaryController.text.trim(),
      externalUrl: _urlController.text.trim().isEmpty
          ? null
          : _urlController.text.trim(),
      contacts: contacts,
    );
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) {
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final key in [_titleKey, _summaryKey]) {
          final fieldContext = key.currentContext;
          if (key.currentState?.hasError == true && fieldContext != null) {
            Scrollable.ensureVisible(fieldContext,
                duration: const Duration(milliseconds: 250), alignment: 0.1);
            break;
          }
        }
      });
      return;
    }

    setState(() {
      _busy = true;
      _banner = null;
    });

    try {
      final draft = _draftFromFields();
      final VacancySubmissionResult result;
      if (_isEditDraft) {
        final existing = widget.existingSubmission!;
        final expected = _rowVersion ?? existing.rowVersion;
        final updated = await _service.updateDraft(
          id: existing.id,
          draft: draft,
          expectedRowVersion: expected,
        );
        if (!updated.ok) {
          if (!mounted) return;
          setState(
              () => _banner = updated.errorMessage ?? 'Не удалось сохранить.');
          return;
        }
        _rowVersion = updated.rowVersion ?? expected + 1;
        result = await _service.resubmit(
          id: existing.id,
          expectedRowVersion: _rowVersion!,
        );
      } else {
        result = await _service.submit(draft);
      }
      if (!mounted) return;
      if (!result.ok) {
        setState(
            () => _banner = result.errorMessage ?? 'Не удалось отправить.');
        return;
      }
      setState(() => _usedLocalFallback = result.isLocalFallback);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
              _isEditDraft ? 'Заявка отправлена снова' : 'Заявка отправлена'),
          content: Text(
            result.isLocalFallback
                ? 'Демо-режим: заявка сохранена локально со статусом '
                    '«отправлена». Публикация только после модерации.'
                : _isEditDraft
                    ? 'Исправленная вакансия снова в очереди модерации.'
                    : 'Вакансия отправлена на модерацию (статус: отправлена). '
                        'Публикация произойдёт только после одобрения.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Понятно'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    OutlineInputBorder fieldBorder(Color color, {double width = 1}) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: width),
        );
    return Scaffold(
      appBar: AppBar(
        title:
            Text(_isEditDraft ? 'Исправить вакансию' : 'Предложить вакансию'),
      ),
      body: Theme(
        data: theme.copyWith(
          inputDecorationTheme: theme.inputDecorationTheme.copyWith(
            filled: true,
            fillColor: colors.surface,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: fieldBorder(colors.outlineVariant),
            enabledBorder:
                fieldBorder(colors.outlineVariant.withValues(alpha: .75)),
            focusedBorder: fieldBorder(colors.primary, width: 1.5),
            errorBorder: fieldBorder(colors.error),
            focusedErrorBorder: fieldBorder(colors.error, width: 1.5),
          ),
        ),
        child: Form(
          key: _formKey,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    // Keep every field registered with Form while scrolling.
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: colors.primaryContainer
                                  .withValues(alpha: .55),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(
                              _usedLocalFallback
                                  ? 'Демо: RPC submit_vacancy недоступен — заявка '
                                      'сохраняется локально.'
                                  : _isEditDraft
                                      ? 'Модератор запросил уточнение. Исправьте заявку и '
                                          'отправьте снова — публикация только после одобрения.'
                                      : 'Ваша заявка не публикуется сразу. Модератор проверит '
                                          'объявление перед публикацией.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer),
                            ),
                          ),
                          if (_clarificationReason != null &&
                              _clarificationReason!.trim().isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFFBEB),
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: const Color(0xFFF59E0B)),
                              ),
                              child: Text(
                                'Комментарий модератора: ${_clarificationReason!.trim()}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: const Color(0xFF92400E),
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          ],
                          if (_banner != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _banner!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error),
                            ),
                          ],
                          const SizedBox(height: 24),
                          const _VacancySectionHeading(
                            icon: Icons.article_outlined,
                            title: 'Объявление',
                            subtitle: 'Расскажите о вакансии',
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            key: _titleKey,
                            controller: _titleController,
                            decoration:
                                const InputDecoration(labelText: 'Название *'),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Обязательное поле'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _companyController,
                            decoration:
                                const InputDecoration(labelText: 'Организация'),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            key: _summaryKey,
                            controller: _summaryController,
                            decoration: const InputDecoration(
                              labelText: 'Краткое описание *',
                              alignLabelWithHint: true,
                            ),
                            maxLines: 2,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Обязательное поле'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _descriptionController,
                            decoration: const InputDecoration(
                                labelText: 'Описание',
                                alignLabelWithHint: true),
                            maxLines: 4,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _requirementsController,
                            decoration: const InputDecoration(
                                labelText: 'Требования',
                                alignLabelWithHint: true),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 24),
                          const _VacancySectionHeading(
                            icon: Icons.work_outline_rounded,
                            title: 'Условия',
                            subtitle: 'Формат, место и оплата',
                          ),
                          const SizedBox(height: 12),
                          _VacancyOptionField<VacancyEmploymentType>(
                            key: ValueKey('employment-$_employmentType'),
                            label: 'Формат занятости',
                            current: _employmentType,
                            options: VacancyEmploymentType.values
                                .map((value) =>
                                    (value: value, label: value.labelRu))
                                .toList(),
                            onChanged: (value) =>
                                setState(() => _employmentType = value),
                          ),
                          const SizedBox(height: 16),
                          _VacancyOptionField<VacancyWorkFormat>(
                            key: ValueKey('format-$_workFormat'),
                            label: 'Местоположение / удалённо',
                            current: _workFormat,
                            options: VacancyWorkFormat.values
                                .map((value) =>
                                    (value: value, label: value.labelRu))
                                .toList(),
                            onChanged: (value) =>
                                setState(() => _workFormat = value),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _locationController,
                            decoration: const InputDecoration(
                              labelText: 'Местоположение (текст)',
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _salaryController,
                            decoration: const InputDecoration(
                              labelText: 'Зарплата (необязательно)',
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _urlController,
                            decoration:
                                const InputDecoration(labelText: 'Ссылка'),
                            keyboardType: TextInputType.url,
                          ),
                          const SizedBox(height: 24),
                          const _VacancySectionHeading(
                            icon: Icons.alternate_email_rounded,
                            title: 'Контакты',
                            subtitle: 'Как с вами связаться',
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _emailController,
                            decoration:
                                const InputDecoration(labelText: 'Email'),
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _phoneController,
                            decoration:
                                const InputDecoration(labelText: 'Телефон'),
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: ProductLoadingIndicator(),
                                  )
                                : Text(
                                    _isEditDraft
                                        ? 'Сохранить и отправить снова'
                                        : 'Отправить на модерацию',
                                  ),
                          ),
                        ]),
                  ],
                )),
          ),
        ),
      ),
    );
  }
}

class _VacancySectionHeading extends StatelessWidget {
  const _VacancySectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, size: 20, color: colors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Text(subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

class _VacancyOptionField<T> extends StatelessWidget {
  const _VacancyOptionField(
      {super.key,
      required this.label,
      required this.current,
      required this.options,
      required this.onChanged});

  final String label;
  final T? current;
  final List<({T value, String label})> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedLabel = options
            .where((option) => option.value == current)
            .map((option) => option.label)
            .firstOrNull ??
        '— не указано —';
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) {
          final colors = Theme.of(sheetContext).colorScheme;
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      Expanded(
                          child: Text(label,
                              style:
                                  Theme.of(sheetContext).textTheme.titleLarge)),
                      IconButton(
                          tooltip: 'Закрыть',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close_rounded)),
                    ]),
                  ),
                  for (final option in [
                    (value: null, label: '— не указано —'),
                    ...options
                  ])
                    ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      minTileHeight: 52,
                      title: Text(option.label),
                      selected: option.value == current,
                      selectedColor: colors.onPrimaryContainer,
                      selectedTileColor: colors.primaryContainer,
                      trailing: option.value == current
                          ? const Icon(Icons.check_rounded, size: 20)
                          : null,
                      onTap: () {
                        onChanged(option.value);
                        Navigator.pop(sheetContext);
                      },
                    ),
                ],
              ),
            ),
          );
        },
      ),
      child: InputDecorator(
        decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.keyboard_arrow_down_rounded)),
        child: Text(selectedLabel),
      ),
    );
  }
}
