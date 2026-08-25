import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/auth/admin_backend_config.dart';
import 'academic_process_calendar_models.dart';
import 'academic_process_calendar_repository.dart';

class AcademicProcessCalendarReviewPanel extends StatefulWidget {
  const AcademicProcessCalendarReviewPanel({super.key, this.repository});

  final AcademicProcessCalendarRepository? repository;

  @override
  State<AcademicProcessCalendarReviewPanel> createState() =>
      _AcademicProcessCalendarReviewPanelState();
}

class _AcademicProcessCalendarReviewPanelState
    extends State<AcademicProcessCalendarReviewPanel> {
  late final AcademicProcessCalendarRepository _repository =
      widget.repository ??
      (AdminBackendConfig.isDemoMode
          ? LocalAcademicProcessCalendarRepository()
          : SupabaseAcademicProcessCalendarRepository());

  final _title = TextEditingController(text: 'График учебного процесса');
  final _versionLabel = TextEditingController(text: '2026/2027 · черновик 1');
  final List<_PeriodControllers> _rows = [_PeriodControllers()];

  AcademicProcessCalendarReferences? _references;
  AcademicProcessAudienceKind _audienceKind = AcademicProcessAudienceKind.plan;
  String? _yearId;
  String? _audienceId;
  String? _versionId;
  String? _sourceName;
  String? _sourceMime;
  String? _localSha256;
  Uint8List? _sourceBytes;
  AcademicProcessDryRunResult? _result;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReferences();
  }

  @override
  void dispose() {
    _title.dispose();
    _versionLabel.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _loadReferences() async {
    try {
      final value = await _repository.loadReferences();
      if (!mounted) return;
      setState(() {
        _references = value;
        _yearId = value.years.isEmpty ? null : value.years.first.id;
        _audienceId = _targets(value).isEmpty ? null : _targets(value).first.id;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить годы и аудитории: $error';
      });
    }
  }

  List<AcademicProcessReference> _targets(
    AcademicProcessCalendarReferences value,
  ) => switch (_audienceKind) {
    AcademicProcessAudienceKind.global => const [],
    AcademicProcessAudienceKind.program => value.programs,
    AcademicProcessAudienceKind.plan => value.plans,
    AcademicProcessAudienceKind.group => value.groups,
  };

  void _invalidateMetadata() {
    _versionId = null;
    _result = null;
  }

  void _invalidateRows() {
    _result = null;
  }

  Future<void> _pickSource() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'pdf'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _error = 'Не удалось прочитать выбранный файл.');
      return;
    }
    final extension = (file.extension ?? '').toLowerCase();
    setState(() {
      _sourceName = file.name;
      _sourceBytes = bytes;
      _sourceMime = switch (extension) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        'pdf' => 'application/pdf',
        _ => 'application/octet-stream',
      };
      _localSha256 = sha256.convert(bytes).toString();
      _error = null;
      _invalidateMetadata();
    });
  }

  void _addRow() {
    setState(() {
      _rows.add(_PeriodControllers(sequence: _rows.length + 1));
      _invalidateRows();
    });
  }

  void _removeRow(int index) {
    if (_rows.length == 1) return;
    setState(() {
      _rows.removeAt(index).dispose();
      _invalidateRows();
    });
  }

  List<AcademicProcessPeriodDraft> _buildRows() {
    return [for (final row in _rows) row.toDraft()];
  }

  Future<void> _runDryRun() async {
    final references = _references;
    if (references == null || _yearId == null) return;
    if (_audienceKind != AcademicProcessAudienceKind.global &&
        _audienceId == null) {
      setState(() => _error = 'Выберите программу, учебный план или группу.');
      return;
    }
    if (_title.text.trim().isEmpty || _versionLabel.text.trim().isEmpty) {
      setState(() => _error = 'Заполните название календаря и версии.');
      return;
    }
    late final List<AcademicProcessPeriodDraft> rows;
    try {
      rows = _buildRows();
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final versionId =
          _versionId ??
          await _repository.createDraftVersion(
            academicYearId: _yearId!,
            audienceKind: _audienceKind,
            audienceId: _audienceId,
            title: _title.text,
            versionLabel: _versionLabel.text,
            sourceFileName: _sourceName,
            sourceMimeType: _sourceMime,
            localSha256: _localSha256,
          );
      if (!mounted) return;
      // Version creation is a committed metadata write. Remember it before
      // dry-run so a transient failure does not create a duplicate on retry.
      if (_versionId != versionId) {
        setState(() => _versionId = versionId);
      }
      final result = await _repository.dryRun(versionId: versionId, rows: rows);
      if (!mounted) return;
      setState(() {
        _result = result;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Dry-run не выполнен: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final references = _references;
    if (references == null) {
      return Center(child: Text(_error ?? 'Справочники недоступны.'));
    }
    final targets = _targets(references);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'График учебного процесса',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'Загрузите официальный рисунок/PDF как источник и вручную проверьте '
          'периоды. OCR в Web не считается надёжным источником данных.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            children: [
              if (_error != null)
                Card(
                  color: const Color(0xFFFFEBEE),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!),
                  ),
                ),
              _buildSourceCard(),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Год и область действия',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: 240,
                            child: DropdownButtonFormField<String>(
                              initialValue: _yearId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Учебный год',
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                for (final year in references.years)
                                  DropdownMenuItem(
                                    value: year.id,
                                    child: Text(year.label),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(() {
                                      _yearId = value;
                                      _invalidateMetadata();
                                    }),
                            ),
                          ),
                          SizedBox(
                            width: 280,
                            child:
                                DropdownButtonFormField<
                                  AcademicProcessAudienceKind
                                >(
                                  initialValue: _audienceKind,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Для кого',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    for (final kind
                                        in AcademicProcessAudienceKind.values)
                                      DropdownMenuItem(
                                        value: kind,
                                        child: Text(kind.label),
                                      ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (value) {
                                          if (value == null) return;
                                          setState(() {
                                            _audienceKind = value;
                                            final next = _targets(references);
                                            _audienceId = next.isEmpty
                                                ? null
                                                : next.first.id;
                                            _invalidateMetadata();
                                          });
                                        },
                                ),
                          ),
                          if (_audienceKind !=
                              AcademicProcessAudienceKind.global)
                            SizedBox(
                              width: 420,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(_audienceKind),
                                initialValue:
                                    targets.any(
                                      (item) => item.id == _audienceId,
                                    )
                                    ? _audienceId
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Программа / план / группа',
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  for (final target in targets)
                                    DropdownMenuItem(
                                      value: target.id,
                                      child: Text(
                                        target.label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (value) => setState(() {
                                        _audienceId = value;
                                        _invalidateMetadata();
                                      }),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _title,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Название календаря',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(_invalidateMetadata),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _versionLabel,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                          labelText: 'Название версии',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(_invalidateMetadata),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Периоды',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _addRow,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить период'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < _rows.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PeriodEditor(
                    key: ValueKey(_rows[index]),
                    controllers: _rows[index],
                    index: index,
                    canRemove: _rows.length > 1,
                    enabled: !_busy,
                    onChanged: () => setState(_invalidateRows),
                    onRemove: () => _removeRow(index),
                  ),
                ),
              if (_result != null) _DryRunCard(result: _result!),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Dry-run не применяет и не публикует график. '
                'Текущие семестры, предметы и чаты не меняются.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _runDryRun,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined),
              label: const Text('Проверить dry-run'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSourceCard() {
    final isImage = _sourceMime?.startsWith('image/') == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isImage && _sourceBytes != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: SizedBox(
                  width: 220,
                  height: 130,
                  child: Image.memory(_sourceBytes!, fit: BoxFit.contain),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Официальный исходник',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _sourceName == null
                        ? 'Файл ещё не выбран. Ручной ввод доступен без файла, '
                              'но перед публикацией источник обязателен.'
                        : '$_sourceName · локальный SHA-256 '
                              '${_localSha256!.substring(0, 12)}…',
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Локальный хеш сохраняется как неподтверждённый: браузер '
                    'не может подтвердить происхождение файла.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickSource,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(_sourceName == null ? 'Выбрать файл' : 'Заменить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodControllers {
  _PeriodControllers({int sequence = 1})
    : key = TextEditingController(text: 'period-$sequence'),
      course = TextEditingController(text: '1'),
      term = TextEditingController(text: '1'),
      starts = TextEditingController(),
      ends = TextEditingController(),
      note = TextEditingController();

  final TextEditingController key;
  final TextEditingController course;
  final TextEditingController term;
  final TextEditingController starts;
  final TextEditingController ends;
  final TextEditingController note;
  AcademicProcessPeriodType type = AcademicProcessPeriodType.study;

  AcademicProcessPeriodDraft toDraft() {
    final courseNumber = int.tryParse(course.text.trim());
    final termInYear = int.tryParse(term.text.trim());
    if (key.text.trim().isEmpty) {
      throw const FormatException('У каждого периода нужен уникальный ключ.');
    }
    if (courseNumber == null || courseNumber < 1 || courseNumber > 10) {
      throw FormatException('Некорректный курс для периода ${key.text}.');
    }
    if (termInYear == null || (termInYear != 1 && termInYear != 2)) {
      throw FormatException(
        'Полугодие должно быть 1 или 2 для периода ${key.text}.',
      );
    }
    final startsOn = DateTime.tryParse(starts.text.trim());
    final endsOn = DateTime.tryParse(ends.text.trim());
    if (startsOn == null || endsOn == null) {
      throw FormatException('Введите даты ГГГГ-ММ-ДД для периода ${key.text}.');
    }
    return AcademicProcessPeriodDraft(
      periodKey: key.text,
      type: type,
      courseNumber: courseNumber,
      termInYear: termInYear,
      startsOn: startsOn,
      endsOn: endsOn,
      sourceNote: note.text,
    );
  }

  void dispose() {
    key.dispose();
    course.dispose();
    term.dispose();
    starts.dispose();
    ends.dispose();
    note.dispose();
  }
}

class _PeriodEditor extends StatelessWidget {
  const _PeriodEditor({
    super.key,
    required this.controllers,
    required this.index,
    required this.canRemove,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final _PeriodControllers controllers;
  final int index;
  final bool canRemove;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 150,
              child: TextField(
                controller: controllers.key,
                enabled: enabled,
                decoration: InputDecoration(labelText: 'Ключ ${index + 1}'),
                onChanged: (_) => onChanged(),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<AcademicProcessPeriodType>(
                initialValue: controllers.type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Тип'),
                items: [
                  for (final type in AcademicProcessPeriodType.values)
                    DropdownMenuItem(value: type, child: Text(type.label)),
                ],
                onChanged: enabled
                    ? (value) {
                        if (value == null) return;
                        controllers.type = value;
                        onChanged();
                      }
                    : null,
              ),
            ),
            _field(controllers.course, 'Курс', 70, enabled, onChanged),
            _field(controllers.term, 'Полугодие', 100, enabled, onChanged),
            _field(
              controllers.starts,
              'Начало ГГГГ-ММ-ДД',
              170,
              enabled,
              onChanged,
            ),
            _field(
              controllers.ends,
              'Конец ГГГГ-ММ-ДД',
              170,
              enabled,
              onChanged,
            ),
            _field(controllers.note, 'Примечание', 220, enabled, onChanged),
            IconButton(
              tooltip: 'Удалить период',
              onPressed: canRemove && enabled ? onRemove : null,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _field(
    TextEditingController controller,
    String label,
    double width,
    bool enabled,
    VoidCallback onChanged,
  ) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        enabled: enabled,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => onChanged(),
      ),
    );
  }
}

class _DryRunCard extends StatelessWidget {
  const _DryRunCard({required this.result});

  final AcademicProcessDryRunResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: result.ok ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.ok
                  ? 'Dry-run прошёл: ${result.newCount} периодов'
                  : 'Dry-run: ошибок ${result.errorCount}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Apply и публикация отключены на этом этапе.',
              style: TextStyle(color: Colors.black54),
            ),
            for (final item in result.items)
              if ((item['errors'] as List? ?? const []).isNotEmpty)
                Text(
                  '• ${item['period_key'] ?? 'строка ${item['row_number']}'}: '
                  '${(item['errors'] as List).join(', ')}',
                ),
          ],
        ),
      ),
    );
  }
}
