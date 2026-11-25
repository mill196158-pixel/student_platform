import 'package:flutter/material.dart';

class PersonalTaskDeadlineButton extends StatefulWidget {
  const PersonalTaskDeadlineButton({
    super.key,
    required this.current,
    required this.save,
  });

  final DateTime? current;
  final Future<void> Function(DateTime date) save;

  @override
  State<PersonalTaskDeadlineButton> createState() =>
      _PersonalTaskDeadlineButtonState();
}

class _PersonalTaskDeadlineButtonState
    extends State<PersonalTaskDeadlineButton> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _edit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final now = DateTime.now();
      final initial = DateUtils.dateOnly(widget.current ?? now);
      final first = DateTime(now.year - 1);
      final last = DateTime(now.year + 5, 12, 31);
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: initial.isBefore(first) ? initial : first,
        lastDate: initial.isAfter(last) ? initial : last,
        helpText: 'Дедлайн задачи',
        cancelText: 'Отмена',
        confirmText: 'Сохранить',
      );
      if (!mounted || picked == null) return;
      await widget.save(picked);
      if (mounted && ModalRoute.of(context)?.isCurrent == true)
        Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.edit_calendar_outlined),
            onPressed: _busy ? null : _edit,
            label: Text(
                widget.current == null ? 'Добавить срок' : 'Изменить срок'),
          ),
          if (_failed)
            Text('Не удалось сохранить срок. Попробуйте ещё раз.',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      );
}
