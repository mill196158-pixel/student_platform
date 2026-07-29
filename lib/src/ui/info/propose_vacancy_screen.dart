import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'vacancy_submission_service.dart';

/// Student form to propose a vacancy (Stage 17 user submission stub).
///
/// Calls `submit_vacancy` via [VacancySubmissionService]; status is always
/// `submitted` — never auto-published.
class ProposeVacancyScreen extends StatefulWidget {
  const ProposeVacancyScreen({
    super.key,
    this.submissionService,
  });

  final VacancySubmissionService? submissionService;

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
      final result = await _service.submit(_draftFromFields());
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
          title: const Text('Заявка отправлена'),
          content: Text(
            result.isLocalFallback
                ? 'Демо-режим: заявка сохранена локально со статусом '
                    '«отправлена». Публикация только после модерации.'
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
        title: const Text('Предложить вакансию'),
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
                    : 'Ваша заявка не публикуется сразу. Модератор проверит '
                        'объявление перед публикацией.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
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
                  : const Text('Отправить на модерацию'),
            ),
          ],
        ),
      ),
    );
  }
}
