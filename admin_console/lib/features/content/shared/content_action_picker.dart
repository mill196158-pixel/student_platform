import 'package:flutter/material.dart';

import 'content_action_model.dart';

/// Picker for structured content actions with human labels (no raw routes in UI).
class ContentActionPicker extends StatefulWidget {
  const ContentActionPicker({
    required this.selection,
    required this.onChanged,
    this.enabled = true,
    this.allowedKinds = const [
      ContentActionKind.appScreen,
      ContentActionKind.referenceArticle,
      ContentActionKind.subject,
      ContentActionKind.vacancy,
      ContentActionKind.externalUrl,
      ContentActionKind.none,
    ],
    this.loadArticleOptions,
    this.loadSubjectOptions,
    this.loadVacancyOptions,
    super.key,
  });

  final ContentActionSelection selection;
  final ValueChanged<ContentActionSelection> onChanged;
  final bool enabled;
  final List<ContentActionKind> allowedKinds;
  final Future<List<ContentActionTargetOption>> Function()? loadArticleOptions;
  final Future<List<ContentActionTargetOption>> Function()? loadSubjectOptions;
  final Future<List<ContentActionTargetOption>> Function()? loadVacancyOptions;

  @override
  State<ContentActionPicker> createState() => _ContentActionPickerState();
}

class _ContentActionPickerState extends State<ContentActionPicker> {
  final _urlController = TextEditingController();
  String? _urlError;
  List<ContentActionTargetOption>? _targetOptions;
  bool _loadingTargets = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = widget.selection.url ?? '';
    _urlError = validateContentExternalUrl(_urlController.text);
    _maybeLoadTargets();
  }

  @override
  void didUpdateWidget(covariant ContentActionPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection &&
        _urlController.text != (widget.selection.url ?? '')) {
      _urlController.text = widget.selection.url ?? '';
      _urlError = validateContentExternalUrl(_urlController.text);
    }
    if (oldWidget.selection.kind != widget.selection.kind) {
      _maybeLoadTargets();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _maybeLoadTargets() async {
    final kind = widget.selection.kind;
    Future<List<ContentActionTargetOption>> Function()? loader;
    switch (kind) {
      case ContentActionKind.referenceArticle:
        loader = widget.loadArticleOptions;
      case ContentActionKind.subject:
        loader = widget.loadSubjectOptions;
      case ContentActionKind.vacancy:
        loader = widget.loadVacancyOptions;
      default:
        loader = null;
    }
    if (loader == null) {
      setState(() {
        _targetOptions = null;
        _loadingTargets = false;
      });
      return;
    }
    setState(() => _loadingTargets = true);
    try {
      final options = await loader();
      if (!mounted) return;
      setState(() {
        _targetOptions = options;
        _loadingTargets = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _targetOptions = const [];
        _loadingTargets = false;
      });
    }
  }

  void _setKind(ContentActionKind kind) {
    widget.onChanged(
      ContentActionSelection(
        kind: kind,
        screenKey: kind == ContentActionKind.appScreen ? 'home' : null,
      ),
    );
    _maybeLoadTargets();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<ContentActionKind>(
          isExpanded: true,
          key: ValueKey('action-kind-${widget.selection.kind}'),
          initialValue: widget.allowedKinds.contains(widget.selection.kind)
              ? widget.selection.kind
              : widget.allowedKinds.first,
          decoration: const InputDecoration(labelText: 'Действие кнопки'),
          items: [
            for (final kind in widget.allowedKinds)
              DropdownMenuItem(
                value: kind,
                child: Text(contentActionKindLabelRu(kind)),
              ),
          ],
          onChanged: !widget.enabled
              ? null
              : (value) {
                  if (value != null) _setKind(value);
                },
        ),
        const SizedBox(height: 8),
        _buildSecondStep(context),
      ],
    );
  }

  Widget _buildSecondStep(BuildContext context) {
    switch (widget.selection.kind) {
      case ContentActionKind.appScreen:
        return DropdownButtonFormField<String>(
          isExpanded: true,
          key: ValueKey('screen-${widget.selection.screenKey}'),
          initialValue:
              kContentAppScreenLabels.containsKey(widget.selection.screenKey)
              ? widget.selection.screenKey
              : 'home',
          decoration: const InputDecoration(labelText: 'Экран приложения'),
          items: [
            for (final entry in kContentAppScreenLabels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: !widget.enabled
              ? null
              : (value) {
                  if (value == null) return;
                  widget.onChanged(widget.selection.copyWith(screenKey: value));
                },
        );
      case ContentActionKind.externalUrl:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _urlController,
              enabled: widget.enabled,
              decoration: InputDecoration(
                labelText: 'Внешняя ссылка',
                hintText: 'https://…',
                errorText: _urlError,
              ),
              keyboardType: TextInputType.url,
              onChanged: (value) {
                final error = validateContentExternalUrl(value);
                setState(() => _urlError = error);
                if (error == null || value.trim().isEmpty) {
                  widget.onChanged(
                    widget.selection.copyWith(url: value.trim()),
                  );
                }
              },
            ),
          ],
        );
      case ContentActionKind.referenceArticle:
      case ContentActionKind.subject:
      case ContentActionKind.vacancy:
        return _buildTargetPicker(context);
      case ContentActionKind.none:
        return const Text(
          'Кнопка не выполняет переход.',
          style: TextStyle(color: Color(0xFF5C6370), fontSize: 13),
        );
    }
  }

  Widget _buildTargetPicker(BuildContext context) {
    if (_loadingTargets) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    final options = _targetOptions;
    if (options == null) {
      return Text(
        'Подключите список целей через callback редактора.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    if (options.isEmpty) {
      return const Text('Нет доступных элементов.');
    }
    return DropdownButtonFormField<String>(
      isExpanded: true,
      key: ValueKey('target-${widget.selection.targetId}'),
      initialValue: options.any((o) => o.id == widget.selection.targetId)
          ? widget.selection.targetId
          : options.first.id,
      decoration: InputDecoration(
        labelText: switch (widget.selection.kind) {
          ContentActionKind.referenceArticle => 'Статья справочника',
          ContentActionKind.subject => 'Предмет',
          ContentActionKind.vacancy => 'Вакансия',
          _ => 'Цель',
        },
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(value: option.id, child: Text(option.label)),
      ],
      onChanged: !widget.enabled
          ? null
          : (value) {
              if (value == null) return;
              widget.onChanged(widget.selection.copyWith(targetId: value));
            },
    );
  }
}
