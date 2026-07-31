import 'dart:developer' as developer;

import 'visual_editor_operation_error.dart';

/// Result of autosaving a working draft (or canonical draft) before publish.
class VisualEditorSavedDraft<T> {
  const VisualEditorSavedDraft({
    required this.item,
    required this.expectedDraftRowVersion,
    this.workingDraftId,
  });

  final T item;
  final int expectedDraftRowVersion;
  final String? workingDraftId;
}

/// Optional media upload step before autosave.
class VisualEditorUploadAdopt {
  const VisualEditorUploadAdopt({this.workingDraftRowVersion});

  final int? workingDraftRowVersion;
}

/// Single-flight publish pipeline for Visual Content Studio editors.
///
/// Order: validate → upload pending → save WD → publish → refetch.
/// Publish is skipped if any prior step fails.
class VisualEditorPublishCoordinator {
  Future<Object?>? _inFlight;

  bool get isPublishing => _inFlight != null;

  /// Runs the working-draft publish pipeline (or canonical publish when
  /// [editingWorkingDraft] is false). Concurrent calls share the in-flight future.
  Future<T> publishChanges<T>({
    required bool editingWorkingDraft,
    required Future<String?> Function() validate,
    Future<VisualEditorUploadAdopt?> Function()? uploadPendingMedia,
    required Future<VisualEditorSavedDraft<T>> Function() saveDraft,
    required Future<T> Function({required int expectedDraftRowVersion})
    publishWorkingDraft,
    Future<T> Function()? publishCanonical,
    required Future<T> Function(T published) refetch,
    void Function(String message)? onDebug,
  }) {
    final existing = _inFlight;
    if (existing != null) {
      return existing.then((value) => value as T);
    }

    final future = _runPublish<T>(
      editingWorkingDraft: editingWorkingDraft,
      validate: validate,
      uploadPendingMedia: uploadPendingMedia,
      saveDraft: saveDraft,
      publishWorkingDraft: publishWorkingDraft,
      publishCanonical: publishCanonical,
      refetch: refetch,
      onDebug: onDebug,
    );
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
  }

  Future<T> _runPublish<T>({
    required bool editingWorkingDraft,
    required Future<String?> Function() validate,
    Future<VisualEditorUploadAdopt?> Function()? uploadPendingMedia,
    required Future<VisualEditorSavedDraft<T>> Function() saveDraft,
    required Future<T> Function({required int expectedDraftRowVersion})
    publishWorkingDraft,
    Future<T> Function()? publishCanonical,
    required Future<T> Function(T published) refetch,
    void Function(String message)? onDebug,
  }) async {
    void log(String message) {
      onDebug?.call(message);
      developer.log(message, name: 'VisualEditorPublish');
    }

    final validationError = await validate();
    if (validationError != null && validationError.trim().isNotEmpty) {
      throw VisualEditorOperationError(
        validationError,
        code: 'validation',
        isValidation: true,
      );
    }

    if (uploadPendingMedia != null) {
      try {
        await uploadPendingMedia();
      } catch (error) {
        final mapped = mapVisualEditorMediaError(error);
        log(mapped.debugDetail ?? mapped.message);
        throw mapped;
      }
    }

    late final VisualEditorSavedDraft<T> saved;
    try {
      saved = await saveDraft();
    } catch (error) {
      final mapped = mapVisualEditorOperationError(error, stage: 'autosave');
      log(mapped.debugDetail ?? mapped.message);
      throw mapped;
    }

    late final T published;
    try {
      if (editingWorkingDraft) {
        published = await publishWorkingDraft(
          expectedDraftRowVersion: saved.expectedDraftRowVersion,
        );
      } else {
        final canonical = publishCanonical;
        if (canonical == null) {
          throw const VisualEditorOperationError(
            'Публикация недоступна для этого состояния карточки.',
            code: 'publish_unavailable',
          );
        }
        published = await canonical();
      }
    } catch (error) {
      if (error is VisualEditorOperationError) rethrow;
      final mapped = mapVisualEditorOperationError(
        error,
        stage: editingWorkingDraft ? 'publish_working_draft' : 'publish',
      );
      log(mapped.debugDetail ?? mapped.message);
      throw mapped;
    }

    try {
      return await refetch(published);
    } catch (error) {
      final mapped = mapVisualEditorOperationError(error, stage: 'refetch');
      log(mapped.debugDetail ?? mapped.message);
      // Publish already succeeded — surface soft failure with published item.
      throw VisualEditorOperationError(
        'Опубликовано, но не удалось обновить данные. Обновите список.',
        code: 'refetch_failed',
        debugDetail: mapped.debugDetail,
      );
    }
  }
}
