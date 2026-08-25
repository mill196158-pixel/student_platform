import 'package:flutter/material.dart';

import '../../../shared/widgets/publication_status_badge.dart';
import 'visual_editor_states.dart';

enum VisualEditorListTab { published, drafts, archived }

extension VisualEditorListTabLabels on VisualEditorListTab {
  String get labelRu => switch (this) {
    VisualEditorListTab.published => 'Опубликовано',
    VisualEditorListTab.drafts => 'Черновики',
    VisualEditorListTab.archived => 'Архив',
  };

  String get emptyMessageRu => switch (this) {
    VisualEditorListTab.published => 'Нет опубликованных',
    VisualEditorListTab.drafts => 'Нет черновиков',
    VisualEditorListTab.archived => 'Архив пуст',
  };
}

class VisualEditorTabCounts {
  const VisualEditorTabCounts({
    required this.published,
    required this.drafts,
    required this.archived,
  });

  final int published;
  final int drafts;
  final int archived;
}

typedef VisualEditorPanelBuilder = Widget Function(BuildContext context);

/// Reusable 3-pane visual editor shell modeled on the News editor layout.
class VisualEditorShell extends StatelessWidget {
  const VisualEditorShell({
    required this.title,
    required this.listTab,
    required this.tabCounts,
    required this.listBuilder,
    required this.previewBuilder,
    required this.propertiesBuilder,
    required this.onTabChanged,
    this.selectedTitle,
    this.statusChip,
    this.originDemoBadge = false,
    this.dirty = false,
    this.busy = false,
    this.publishing = false,
    this.banner,
    this.defaultInfoMessage =
        'Изменения сохраняются на сервере. Публикация видна студентам сразу.',
    this.canWrite = true,
    this.canPublish = true,
    this.canUnpublish = true,
    this.onCreate,
    this.onSaveDraft,
    this.onPublish,
    this.onUnpublish,
    this.onVersions,
    this.onPopDirtyConfirm,
    this.editingWorkingDraft = false,
    this.onDiscardWorkingDraft,
    this.onDiscardLocalChanges,
    this.isPublished,
    this.isArchived,
    super.key,
  });

  final String title;
  final String? selectedTitle;
  final String? statusChip;
  final bool originDemoBadge;
  final bool dirty;
  final bool busy;
  final bool publishing;
  final String? banner;
  final String defaultInfoMessage;
  final bool canWrite;
  final bool canPublish;
  final bool canUnpublish;
  final VisualEditorListTab listTab;
  final ValueChanged<VisualEditorListTab> onTabChanged;
  final VisualEditorTabCounts tabCounts;
  final VisualEditorPanelBuilder listBuilder;
  final VisualEditorPanelBuilder previewBuilder;
  final VisualEditorPanelBuilder propertiesBuilder;
  final VoidCallback? onCreate;
  final VoidCallback? onSaveDraft;
  final VoidCallback? onPublish;
  final VoidCallback? onUnpublish;
  final VoidCallback? onVersions;
  final Future<void> Function()? onPopDirtyConfirm;
  final bool editingWorkingDraft;
  final VoidCallback? onDiscardWorkingDraft;
  final VoidCallback? onDiscardLocalChanges;

  /// Typed lifecycle state for domains whose statuses are not generic content.
  final bool? isPublished;
  final bool? isArchived;

  bool get _isPublished => isPublished ?? statusChip == 'Опубликован';
  bool get _isArchived => isArchived ?? statusChip == 'В архиве';
  bool get _hasSelection => selectedTitle != null || statusChip != null;
  bool get _actionsLocked => busy || publishing;

  Future<void> _handlePopAttempt(BuildContext context) async {
    if (onPopDirtyConfirm != null) {
      await onPopDirtyConfirm!();
      return;
    }
    final navigator = Navigator.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Несохранённые изменения'),
        content: const Text('Выйти без сохранения черновика?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (discard == true && context.mounted) {
      navigator.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handlePopAttempt(context);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _VisualEditorHeader(
            title: title,
            selectedTitle: selectedTitle,
            statusChip: statusChip,
            originDemoBadge: originDemoBadge,
            dirty: dirty,
            busy: _actionsLocked,
            publishing: publishing,
            banner: banner,
            defaultInfoMessage: defaultInfoMessage,
            canWrite: canWrite,
            canPublish: canPublish,
            canUnpublish: canUnpublish,
            isPublished: _isPublished,
            isArchived: _isArchived,
            hasSelection: _hasSelection,
            onSaveDraft: onSaveDraft,
            onPublish: onPublish,
            onUnpublish: onUnpublish,
            onVersions: onVersions,
            editingWorkingDraft: editingWorkingDraft,
            onDiscardWorkingDraft: onDiscardWorkingDraft,
            onDiscardLocalChanges: onDiscardLocalChanges,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _VisualEditorBody(
              listBuilder: listBuilder,
              previewBuilder: previewBuilder,
              propertiesBuilder: propertiesBuilder,
            ),
          ),
        ],
      ),
    );
  }
}

class _VisualEditorHeader extends StatelessWidget {
  const _VisualEditorHeader({
    required this.title,
    required this.selectedTitle,
    required this.statusChip,
    required this.originDemoBadge,
    required this.dirty,
    required this.busy,
    required this.publishing,
    required this.banner,
    required this.defaultInfoMessage,
    required this.canWrite,
    required this.canPublish,
    required this.canUnpublish,
    required this.isPublished,
    required this.isArchived,
    required this.hasSelection,
    required this.onSaveDraft,
    required this.onPublish,
    required this.onUnpublish,
    required this.onVersions,
    required this.editingWorkingDraft,
    required this.onDiscardWorkingDraft,
    required this.onDiscardLocalChanges,
  });

  final String title;
  final String? selectedTitle;
  final String? statusChip;
  final bool originDemoBadge;
  final bool dirty;
  final bool busy;
  final bool publishing;
  final String? banner;
  final String defaultInfoMessage;
  final bool canWrite;
  final bool canPublish;
  final bool canUnpublish;
  final bool isPublished;
  final bool isArchived;
  final bool hasSelection;
  final VoidCallback? onSaveDraft;
  final VoidCallback? onPublish;
  final VoidCallback? onUnpublish;
  final VoidCallback? onVersions;
  final bool editingWorkingDraft;
  final VoidCallback? onDiscardWorkingDraft;
  final VoidCallback? onDiscardLocalChanges;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (statusChip != null) PublicationStatusBadge(status: statusChip!),
            if (originDemoBadge) const _HeaderDemoBadge(),
            if (editingWorkingDraft) const _WorkingDraftChip(),
            if (dirty) const _DirtyIndicator(),
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        if (selectedTitle != null && selectedTitle!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            selectedTitle!,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFF5C6370),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            if (onSaveDraft != null)
              OutlinedButton.icon(
                onPressed: busy || !canWrite || isArchived ? null : onSaveDraft,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Сохранить черновик'),
              ),
            if (onVersions != null)
              OutlinedButton.icon(
                onPressed: busy || !hasSelection ? null : onVersions,
                icon: const Icon(Icons.history_rounded),
                label: const Text('История версий'),
              ),
            if (onDiscardLocalChanges != null)
              OutlinedButton.icon(
                onPressed: busy || !canWrite ? null : onDiscardLocalChanges,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Отменить правки'),
              ),
            if (editingWorkingDraft) ...[
              if (onPublish != null)
                FilledButton.icon(
                  onPressed: busy || !canPublish || isArchived || !hasSelection
                      ? null
                      : onPublish,
                  icon: publishing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.publish_outlined),
                  label: Text(
                    publishing ? 'Публикуем…' : 'Опубликовать изменения',
                  ),
                ),
              if (onDiscardWorkingDraft != null)
                OutlinedButton.icon(
                  onPressed: busy || !canWrite ? null : onDiscardWorkingDraft,
                  icon: const Icon(Icons.undo_rounded),
                  label: const Text('Отменить правки'),
                ),
            ] else ...[
              if (isPublished && onUnpublish != null)
                FilledButton.tonalIcon(
                  onPressed: busy || !canUnpublish ? null : onUnpublish,
                  icon: const Icon(Icons.unpublished_outlined),
                  label: const Text('Снять с публикации'),
                ),
              if (!isPublished && onPublish != null)
                FilledButton.icon(
                  onPressed: busy || !canPublish || isArchived || !hasSelection
                      ? null
                      : onPublish,
                  icon: publishing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.publish_outlined),
                  label: Text(publishing ? 'Публикуем…' : 'Опубликовать'),
                ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        if (banner != null)
          VisualEditorBanner.error(text: banner!)
        else
          VisualEditorBanner.info(
            text: dirty
                ? 'Есть несохранённые изменения. Сохраните черновик, чтобы не потерять правки.'
                : defaultInfoMessage,
          ),
      ],
    );
  }
}

class _VisualEditorBody extends StatelessWidget {
  const _VisualEditorBody({
    required this.listBuilder,
    required this.previewBuilder,
    required this.propertiesBuilder,
  });

  final VisualEditorPanelBuilder listBuilder;
  final VisualEditorPanelBuilder previewBuilder;
  final VisualEditorPanelBuilder propertiesBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 3-pane from 1280; between 860–1279 keep phone+props with list below.
        final wide = constraints.maxWidth >= 1280;
        final medium = constraints.maxWidth >= 860;

        final list = listBuilder(context);
        final phone = previewBuilder(context);
        final props = propertiesBuilder(context);

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth >= 1440 ? 360 : 340,
                child: list,
              ),
              const SizedBox(width: 14),
              Expanded(flex: 5, child: phone),
              const SizedBox(width: 14),
              SizedBox(
                width: constraints.maxWidth >= 1440 ? 380 : 360,
                child: props,
              ),
            ],
          );
        }
        if (medium) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    Expanded(flex: 5, child: phone),
                    const SizedBox(height: 12),
                    SizedBox(height: 260, child: list),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(width: 360, child: props),
            ],
          );
        }
        return ListView(
          children: [
            SizedBox(height: 520, child: phone),
            const SizedBox(height: 12),
            SizedBox(height: 260, child: list),
            const SizedBox(height: 12),
            SizedBox(height: 720, child: props),
          ],
        );
      },
    );
  }
}

class _HeaderDemoBadge extends StatelessWidget {
  const _HeaderDemoBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x1F6656D9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF6656D9), width: 1.2),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          'Демо',
          style: TextStyle(
            color: Color(0xFF4A3FA8),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _WorkingDraftChip extends StatelessWidget {
  const _WorkingDraftChip();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x1F1565C0),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF1565C0), width: 1.2),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          'Черновик изменений',
          style: TextStyle(
            color: Color(0xFF0D47A1),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _DirtyIndicator extends StatelessWidget {
  const _DirtyIndicator();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x29C9851F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFC9851F), width: 1.2),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          'Есть правки',
          style: TextStyle(
            color: Color(0xFF8A5A0F),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
