import 'package:supabase_flutter/supabase_flutter.dart';

import 'content_action_model.dart';

/// Shared RU messages for Visual Editor save/publish/upload failures.
class VisualEditorOperationError implements Exception {
  const VisualEditorOperationError(
    this.message, {
    this.code,
    this.isForbidden = false,
    this.isConflict = false,
    this.isNetwork = false,
    this.isValidation = false,
    this.isMedia = false,
    this.debugDetail,
  });

  final String message;
  final String? code;
  final bool isForbidden;
  final bool isConflict;
  final bool isNetwork;
  final bool isValidation;
  final bool isMedia;

  /// Safe technical detail for debug logs (never JWT / signed URL / secrets).
  final String? debugDetail;

  @override
  String toString() => message;
}

/// Classify repository / transport / Edge errors into operator-facing messages.
VisualEditorOperationError mapVisualEditorOperationError(
  Object error, {
  String stage = 'operation',
}) {
  if (error is VisualEditorOperationError) return error;

  if (error is PostgrestException) {
    return _mapPostgrest(error, stage: stage);
  }

  if (error is FunctionException) {
    final details = error.details;
    final detailText = details is Map
        ? (details['error'] ?? details['message'] ?? details).toString()
        : details?.toString() ?? '';
    final blob = '${error.reasonPhrase ?? ''} $detailText ${error.toString()}'
        .toLowerCase();
    final code = _extractKnownCode(blob);
    if (code != null) {
      return _fromCode(code, stage: stage, raw: detailText);
    }
  }

  final raw = error.toString();
  final lower = raw.toLowerCase();
  final code = _extractKnownCode(lower);

  if (_isNetwork(lower)) {
    return VisualEditorOperationError(
      'Нет соединения. Изменения остались в редакторе',
      code: code ?? 'network',
      isNetwork: true,
      debugDetail: _safeDebug(stage, raw),
    );
  }
  if (code != null) {
    return _fromCode(code, stage: stage, raw: raw);
  }

  return VisualEditorOperationError(
    'Не удалось выполнить операцию. Попробуйте ещё раз.',
    debugDetail: _safeDebug(stage, raw),
  );
}

VisualEditorOperationError mapVisualEditorMediaError(Object error) {
  final mapped = mapVisualEditorOperationError(error, stage: 'media_upload');
  if (mapped.isMedia || mapped.code != null) {
    return VisualEditorOperationError(
      mapped.isMedia
          ? mapped.message
          : 'Не удалось загрузить изображение. Черновик сохранён, публикация не выполнена',
      code: mapped.code ?? 'media_upload_failed',
      isMedia: true,
      isForbidden: mapped.isForbidden,
      isConflict: mapped.isConflict,
      isNetwork: mapped.isNetwork,
      debugDetail: mapped.debugDetail,
    );
  }
  return VisualEditorOperationError(
    'Не удалось загрузить изображение. Черновик сохранён, публикация не выполнена',
    code: 'media_upload_failed',
    isMedia: true,
    debugDetail: mapped.debugDetail,
  );
}

VisualEditorOperationError _mapPostgrest(
  PostgrestException error, {
  required String stage,
}) {
  final blob = [
    error.code,
    error.message,
    error.details,
    error.hint,
  ].whereType<Object>().join(' ').toLowerCase();
  final code = _extractKnownCode(blob) ?? error.code;

  if (code == '42501' || blob.contains('forbidden')) {
    return _fromCode('forbidden', stage: stage, raw: error.message);
  }
  if (code == '28000' || blob.contains('not_authenticated')) {
    return const VisualEditorOperationError(
      'Требуется вход. Войдите снова.',
      code: 'not_authenticated',
    );
  }
  if (_isNetwork(blob)) {
    return VisualEditorOperationError(
      'Нет соединения. Изменения остались в редакторе',
      code: 'network',
      isNetwork: true,
      debugDetail: _safeDebug(stage, error.message),
    );
  }

  if (code != null && _knownCodes.contains(code)) {
    return _fromCode(code, stage: stage, raw: error.message);
  }
  final extracted = _extractKnownCode(blob);
  if (extracted != null) {
    return _fromCode(extracted, stage: stage, raw: error.message);
  }

  // Keep specific validation fragments when present.
  if (blob.contains('unknown_payload_keys') ||
      blob.contains('missing_field_') ||
      blob.contains('invalid_')) {
    return VisualEditorOperationError(
      'Проверьте поля карточки: ${_shortValidation(error.message)}',
      code: 'validation',
      isValidation: true,
      debugDetail: _safeDebug(stage, error.message),
    );
  }

  return VisualEditorOperationError(
    'Не удалось выполнить операцию. Попробуйте ещё раз.',
    debugDetail: _safeDebug(stage, error.message),
  );
}

VisualEditorOperationError _fromCode(
  String code, {
  required String stage,
  required String raw,
}) {
  switch (code) {
    case 'working_draft_required':
    case 'working_draft_not_found':
      return VisualEditorOperationError(
        'Сначала создайте черновик изменений',
        code: code,
        debugDetail: _safeDebug(stage, raw),
      );
    case 'working_draft_exists':
      return VisualEditorOperationError(
        'Сначала отмените черновик изменений',
        code: code,
        isValidation: true,
        debugDetail: _safeDebug(stage, raw),
      );
    case 'row_version_conflict':
    case 'row_version_required':
    case 'conflict':
    case 'canonical_changed_rebase_required':
    case 'draft_conflict':
      return VisualEditorOperationError(
        'Карточка изменилась в другой вкладке. Обновили данные — проверьте изменения и повторите',
        code: code,
        isConflict: true,
        debugDetail: _safeDebug(stage, raw),
      );
    case 'invalid_schema_upgrade':
      return VisualEditorOperationError(
        'Нельзя сохранить эту версию схемы. Обновите карточку и повторите',
        code: code,
        isValidation: true,
        debugDetail: _safeDebug(stage, raw),
      );
    case 'visual_studio_v2_publish_disabled':
      return VisualEditorOperationError(
        kVisualStudioV2PublishBlockedMessageRu,
        code: code,
        debugDetail: _safeDebug(stage, raw),
      );
    case 'forbidden':
      return VisualEditorOperationError(
        stage == 'publish' || stage == 'publish_working_draft'
            ? 'Недостаточно прав для публикации'
            : 'Недостаточно прав для этого действия.',
        code: 'forbidden',
        isForbidden: true,
        debugDetail: _safeDebug(stage, raw),
      );
    case 'not_found':
    case 'P0002':
      return VisualEditorOperationError(
        'Карточка не найдена.',
        code: 'not_found',
        debugDetail: _safeDebug(stage, raw),
      );
    case 'draft_only':
    case 'archived_immutable':
    case 'intent_expired':
    case 'storage_object_missing':
    case 'mime_mismatch':
    case 'invalid_mime':
    case 'invalid_byte_size':
      return VisualEditorOperationError(
        'Не удалось загрузить изображение. Черновик сохранён, публикация не выполнена',
        code: code,
        isMedia: true,
        debugDetail: _safeDebug(stage, raw),
      );
    default:
      if (code.startsWith('missing_field_') ||
          code.startsWith('invalid_') ||
          code.startsWith('unknown_')) {
        return VisualEditorOperationError(
          'Проверьте поля карточки: $code',
          code: code,
          isValidation: true,
          debugDetail: _safeDebug(stage, raw),
        );
      }
      return VisualEditorOperationError(
        'Не удалось выполнить операцию. Попробуйте ещё раз.',
        code: code,
        debugDetail: _safeDebug(stage, raw),
      );
  }
}

const _knownCodes = {
  'working_draft_required',
  'working_draft_not_found',
  'working_draft_exists',
  'row_version_conflict',
  'row_version_required',
  'conflict',
  'canonical_changed_rebase_required',
  'draft_conflict',
  'invalid_schema_upgrade',
  'visual_studio_v2_publish_disabled',
  'forbidden',
  'not_found',
  'draft_only',
  'archived_immutable',
  'intent_expired',
  'storage_object_missing',
  'mime_mismatch',
  'invalid_mime',
  'invalid_byte_size',
};

String? _extractKnownCode(String blob) {
  for (final code in _knownCodes) {
    if (blob.contains(code)) return code;
  }
  final match = RegExp(
    r'\b(missing_field_[a-z0-9_]+|invalid_[a-z0-9_]+|unknown_payload_keys)\b',
  ).firstMatch(blob);
  return match?.group(1);
}

bool _isNetwork(String blob) {
  return blob.contains('socket') ||
      blob.contains('timeout') ||
      blob.contains('timed out') ||
      blob.contains('failed host lookup') ||
      blob.contains('connection') ||
      blob.contains('network') ||
      blob.contains('clientexception') ||
      blob.contains('xmlhttprequest');
}

String _shortValidation(String message) {
  final trimmed = message.trim();
  if (trimmed.length <= 120) return trimmed;
  return '${trimmed.substring(0, 117)}...';
}

String _safeDebug(String stage, String raw) {
  var text = raw;
  text = text.replaceAll(
    RegExp(r'bearer\s+[a-z0-9._\-]+', caseSensitive: false),
    'bearer [redacted]',
  );
  text = text.replaceAll(
    RegExp(r'eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'),
    '[jwt-redacted]',
  );
  text = text.replaceAll(
    RegExp(r'https?://\S+token=\S+', caseSensitive: false),
    '[signed-url-redacted]',
  );
  if (text.length > 240) text = '${text.substring(0, 237)}...';
  return '$stage: $text';
}
