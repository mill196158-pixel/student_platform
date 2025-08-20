// lib/src/ui/learning/data/learning_repository.dart
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/file_item.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';

abstract class LearningRepository {
  // Команды
  Future<List<Team>> loadTeams(String groupCode);
  Future<void> saveTeams(List<Team> teams);
  Future<String> joinByInviteCode(String code);

  // Чат
  Future<List<Message>> loadChat(String teamId);

  /// Возвращает true, если сообщение успешно отправлено на сервер.
  /// Если false — значит упало (или сервер вернул пусто), мы оставляем локально.
  Future<bool> saveChat(String teamId, List<Message> messages);

  // Файлы
  Future<List<FileItem>> loadFiles(String teamId);
  Future<void> saveFiles(String teamId, List<FileItem> files);

  // Задания
  Future<List<Assignment>> loadAssignments(String teamId);
  Future<void> saveAssignments(String teamId, List<Assignment> items);

  // Настройки
  Future<Set<String>> loadHiddenTeamIds();
  Future<void> saveHiddenTeamIds(Set<String> ids);
  Future<String?> loadViewMode();
  Future<void> saveViewMode(String mode);
}
