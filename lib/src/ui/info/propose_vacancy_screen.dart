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
    if (!_formKey.currentState!.validate()) return;

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
          setState(() => _banner = updated.errorMessage ?? 'Не удалось сохранить.');
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
        setState(() => _banner = result.errorMessage ?? 'Не удалось отправить.');
        return;
      }
      setState(() => _usedLocalFallback = result.isLocalFallback);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_isEditDraft ? 'Заявка отправлена снова' : 'Заявка отправлена'),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditDraft ? 'Исправить вакансию' : 'Предложить вакансию'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
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
                style: Theme.of(context).textTheme.bodyMedium,
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
                  border: Border.all(color: const Color(0xFFF59E0B)),
                ),
                child: Text(
                  'Комментарий модератора: ${_clarificationReason!.trim()}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'Название *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Обязательное поле' : null,
            ),
            TextFormField(
              controller: _companyController,
              decoration: const InputDecoration(labelText: 'Организация'),
            ),
            TextFormField(
              controller: _summaryController,
              decoration: const InputDecoration(
                labelText: 'Краткое описание *',
              ),
              maxLines: 2,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Обязательное поле' : null,
            ),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: 'Описание'),
              maxLines: 4,
            ),
            TextFormField(
              controller: _requirementsController,
              decoration: const InputDecoration(labelText: 'Требования'),
              maxLines: 3,
            ),
            DropdownButtonFormField<VacancyEmploymentType?>(
              key: ValueKey('employment-$_employmentType'),
              initialValue: _employmentType,
              decoration: const InputDecoration(labelText: 'Формат занятости'),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('— не указано —'),
                ),
                ...VacancyEmploymentType.values.map(
                  (e) => DropdownMenuItem(value: e, child: Text(e.labelRu)),
                ),
              ],
              onChanged: (v) => setState(() => _employmentType = v),
            ),
            DropdownButtonFormField<VacancyWorkFormat?>(
              key: ValueKey('format-$_workFormat'),
              initialValue: _workFormat,
              decoration: const InputDecoration(
                labelText: 'Местоположение / удалённо',
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('— не указано —'),
                ),
                ...VacancyWorkFormat.values.map(
                  (e) => DropdownMenuItem(value: e, child: Text(e.labelRu)),
                ),
              ],
              onChanged: (v) => setState(() => _workFormat = v),
            ),
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: 'Местоположение (текст)',
              ),
            ),
            TextFormField(
              controller: _salaryController,
              decoration: const InputDecoration(
                labelText: 'Зарплата (необязательно)',
              ),
            ),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(labelText: 'Ссылка'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Text(
              'Контакты',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            TextFormField(
              controller: _emailController,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
            ),
            TextFormField(
              controller: _phoneController,
              decoration: const InputDecoration(labelText: 'Телефон'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _isEditDraft
                          ? 'Сохранить и отправить снова'
                          : 'Отправить на модерацию',
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
