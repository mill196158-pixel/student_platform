import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/group_action_labels.dart';

void main() {
  test('topic follow-up uses selected option, not selection title', () {
    expect(topicFollowUpTitle('хоронить слона'), 'Подготовить «хоронить слона»');
  });

  test('collection my_pick_text maps reported/confirmed as done for participant',
      () {
    expect(collectionMyPickIsReported('Отметил перевод'), isTrue);
    expect(collectionMyPickIsConfirmed('Отметил перевод'), isFalse);
    expect(collectionMyPickIsConfirmed('Перевод получен'), isTrue);
    expect(collectionMyPickIsReported('Перевод получен'), isFalse);
    expect(collectionMyPickIsDoneForParticipant('Отметил перевод'), isTrue);
    expect(collectionMyPickIsDoneForParticipant('Перевод получен'), isTrue);
    expect(collectionHomeStatusLine('Отметил перевод'), 'Исполнено');
    expect(collectionHomeStatusLine('Перевод получен'), 'Исполнено');
    expect(collectionHomeStatusLine(null), isNull);
  });

  test('display labels are the new copy', () {
    expect(kTopicKindLabel, 'Темы');
    expect(kTopicCreateActionLabel, 'Создать список тем');
    expect(kCollectionKindLabel, 'Сбор');
    expect(kTopicClosedLabel, 'Темы закрыты');
    expect(kCollectionClosedLabel, 'Сбор закрыт');
    expect(collectionParticipantStatusLabel('reported'), 'Исполнено');
    expect(collectionParticipantIsDone('reported'), isTrue);
  });
}
