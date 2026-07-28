import 'package:flutter/material.dart';

import '../data/chat_group_actions_repository.dart';

/// Foundation form for a group collection (group-space chat only).
class CreateCollectionScreen extends StatefulWidget {
  const CreateCollectionScreen({
    super.key,
    this.repository,
  });

  final ChatGroupActionsRepository? repository;

  @override
  State<CreateCollectionScreen> createState() => _CreateCollectionScreenState();
}

class _CreateCollectionScreenState extends State<CreateCollectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _purposeCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _instructionsCtrl = TextEditingController();
  final _paymentCtrl = TextEditingController();
  DateTime? _deadline;
  bool _saving = false;

  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _purposeCtrl.dispose();
    _descCtrl.dispose();
    _amountCtrl.dispose();
    _instructionsCtrl.dispose();
    _paymentCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
      initialDate: now,
      helpText: 'Скинуться до',
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 2))),
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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await _repo.createCollection(
        title: _titleCtrl.text.trim(),
        purpose: _purposeCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        deadlineAt: _deadline,
        amountOptional: double.tryParse(_amountCtrl.text.trim()),
        instructions: _instructionsCtrl.text.trim(),
        paymentDetails: _paymentCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('«Скинуться» опубликовано в чат')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать «Скинуться»')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmt(DateTime? dt) {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Скинуться')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Название'),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Укажите название' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _purposeCtrl,
              decoration: const InputDecoration(labelText: 'Цель сбора'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Описание'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Сумма с человека (необязательно)',
                hintText: '₽',
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Скинуться до'),
              subtitle: Text(_fmt(_deadline)),
              trailing: const Icon(Icons.event_outlined),
              onTap: _pickDeadline,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _instructionsCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Инструкции для участников',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _paymentCtrl,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Реквизиты / как перевести',
                hintText: 'Карта, СБП, комментарий к переводу',
              ),
            ),
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Приложение не принимает платежи. Переводы выполняются '
                  'вне приложения по указанным реквизитам. Организатор '
                  'отмечает участие и поступление вручную.',
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Создать сбор'),
            ),
          ],
        ),
      ),
    );
  }
}
