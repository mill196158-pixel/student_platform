// Display-only Russian labels for group actions (Stage 13.12.3+).
//
// Wire values (`topic_selection`, `collection`) and legacy message prefixes
// (`Выбор темы:`, `Запись на тему:`, `Скинуться:`) stay unchanged for parsers.

/// Kind label for a topic selection (AppBar, cards, lists).
const String kTopicKindLabel = 'Темы';

/// Plus-menu / create-flow title for a topic selection.
const String kTopicCreateActionLabel = 'Создать список тем';

/// Kind chip / list label for a money collection.
const String kCollectionKindLabel = 'Сбор';

/// Longer collection label where a short «Сбор» is ambiguous.
const String kCollectionKindLabelLong = 'Сбор денег';

/// Flip to `true` after remote apply of
/// `20260728185500_stage13_12_4_collection_deadline_update.sql`.
const bool kCollectionDeadlineRescheduleEnabled = true;

/// Closed/compact copy for a topic selection.
const String kTopicClosedLabel = 'Темы закрыты';

/// Closed/compact copy for a money collection.
const String kCollectionClosedLabel = 'Сбор закрыт';

/// Follow-up task title after the user claimed a topic option.
String topicFollowUpTitle(String selectedOptionTitle) {
  final t = selectedOptionTitle.trim();
  if (t.isEmpty) return 'Подготовить тему';
  return 'Подготовить «$t»';
}

/// Whether [myPickText] from `list_my_group_action_deadlines` means the
/// organizer already confirmed the transfer (hide from upcoming).
bool collectionMyPickIsConfirmed(String? myPickText) {
  final t = (myPickText ?? '').trim().toLowerCase();
  return t.contains('перевод получен') || t == 'подтверждено';
}

/// Whether the user has self-reported a transfer.
///
/// Product rule (13.12.4): for the participant this already counts as done
/// («Исполнено») — organizers still review via contribution progress RPCs.
bool collectionMyPickIsReported(String? myPickText) {
  final t = (myPickText ?? '').trim().toLowerCase();
  if (collectionMyPickIsConfirmed(myPickText)) return false;
  return t.contains('отметил перевод') ||
      t.contains('на проверке') ||
      t.contains('перевёл') ||
      t.contains('исполнено');
}

/// True when the participant should no longer see this collection in upcoming.
bool collectionMyPickIsDoneForParticipant(String? myPickText) {
  return collectionMyPickIsConfirmed(myPickText) ||
      collectionMyPickIsReported(myPickText);
}

/// Home status line for a collection row (participant-facing).
String? collectionHomeStatusLine(String? myPickText) {
  if (collectionMyPickIsDoneForParticipant(myPickText)) return 'Исполнено';
  return null;
}

/// Participant-facing status from wire `my_status` on a collection card/details.
String collectionParticipantStatusLabel(String? myStatus) {
  switch ((myStatus ?? 'none').trim()) {
    case 'confirmed':
    case 'reported':
    case 'pending_review':
    case 'pending':
      return 'Исполнено';
    case 'not_received':
      return 'Не поступило';
    case 'needs_clarification':
      return 'Нужно уточнение';
    default:
      return 'Ожидает перевода';
  }
}

bool collectionParticipantIsDone(String? myStatus) {
  switch ((myStatus ?? 'none').trim()) {
    case 'confirmed':
    case 'reported':
    case 'pending_review':
    case 'pending':
      return true;
    default:
      return false;
  }
}
