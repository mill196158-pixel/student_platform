import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

/// Category bucket for grouping icons in the visual picker.
enum ContentIconCategory {
  navigation('Навигация'),
  study('Учёба'),
  help('Справка'),
  people('Люди'),
  media('Медиа'),
  communication('Общение'),
  actions('Действия'),
  misc('Разное');

  const ContentIconCategory(this.labelRu);

  final String labelRu;
}

/// One selectable icon entry in the admin catalog.
class ContentIconEntry {
  const ContentIconEntry({
    required this.key,
    required this.labelRu,
    required this.category,
  });

  final String key;
  final String labelRu;
  final ContentIconCategory category;

  IconData get iconData => adminContentIconForKey(key);
}

/// Resolves icon data for admin catalog keys (extends student_ui mapping).
IconData adminContentIconForKey(String key) {
  switch (key) {
    case 'menu_book':
      return Icons.menu_book_outlined;
    case 'library_books':
      return Icons.library_books_outlined;
    case 'assignment':
      return Icons.assignment_outlined;
    case 'quiz':
      return Icons.quiz_outlined;
    case 'science':
      return Icons.science_outlined;
    case 'calculate':
      return Icons.calculate_outlined;
    case 'home':
      return Icons.home_outlined;
    case 'calendar_today':
      return Icons.calendar_today_outlined;
    case 'explore':
      return Icons.explore_outlined;
    case 'upload':
      return Icons.upload_rounded;
    case 'open_in_new':
      return Icons.open_in_new_rounded;
    case 'link':
      return Icons.link_rounded;
    case 'groups':
      return Icons.groups_outlined;
    case 'person':
      return Icons.person_outline_rounded;
    case 'school_outlined':
      return Icons.school_outlined;
    case 'emoji_events':
      return Icons.emoji_events_outlined;
    case 'star':
      return Icons.star_outline_rounded;
    case 'favorite':
      return Icons.favorite_border_rounded;
    case 'lightbulb':
      return Icons.lightbulb_outline_rounded;
    case 'tips_and_updates':
      return Icons.tips_and_updates_outlined;
    case 'campaign':
      return Icons.campaign_outlined;
    case 'notifications':
      return Icons.notifications_outlined;
    case 'chat':
      return Icons.chat_bubble_outline_rounded;
    case 'forum':
      return Icons.forum_outlined;
    case 'image':
      return Icons.image_outlined;
    case 'photo_camera':
      return Icons.photo_camera_outlined;
    case 'videocam':
      return Icons.videocam_outlined;
    case 'play_circle':
      return Icons.play_circle_outline_rounded;
    case 'headphones':
      return Icons.headphones_outlined;
    case 'article':
      return Icons.article_outlined;
    case 'auto_awesome':
      return Icons.auto_awesome_outlined;
    case 'verified':
      return Icons.verified_outlined;
    case 'security':
      return Icons.security_outlined;
    case 'health_and_safety':
      return Icons.health_and_safety_outlined;
    case 'support_agent':
      return Icons.support_agent_outlined;
    case 'contact_support':
      return Icons.contact_support_outlined;
    case 'event':
      return Icons.event_outlined;
    case 'schedule':
      return Icons.schedule_outlined;
    case 'bookmark':
      return Icons.bookmark_border_rounded;
    default:
      return contentIconForKey(key);
  }
}

/// Curated allowlist aligned with [contentIconForKey] plus common admin picks.
const List<ContentIconEntry> kContentIconCatalog = [
  ContentIconEntry(
    key: 'psychology',
    labelRu: 'Психология / поддержка',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'psychology_alt_outlined',
    labelRu: 'Психология (контур)',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'help',
    labelRu: 'Помощь',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'info',
    labelRu: 'Информация',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'school',
    labelRu: 'Учёба',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'menu_book',
    labelRu: 'Обучение',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'library_books',
    labelRu: 'Библиотека',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'description',
    labelRu: 'Документ',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'assignment',
    labelRu: 'Задание',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'quiz',
    labelRu: 'Тест',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'science',
    labelRu: 'Наука',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'computer',
    labelRu: 'Компьютер',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'calculate',
    labelRu: 'Расчёты',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'home',
    labelRu: 'Главная',
    category: ContentIconCategory.navigation,
  ),
  ContentIconEntry(
    key: 'calendar_today',
    labelRu: 'Расписание',
    category: ContentIconCategory.navigation,
  ),
  ContentIconEntry(
    key: 'map',
    labelRu: 'Карта',
    category: ContentIconCategory.navigation,
  ),
  ContentIconEntry(
    key: 'explore',
    labelRu: 'Обзор',
    category: ContentIconCategory.navigation,
  ),
  ContentIconEntry(
    key: 'login',
    labelRu: 'Вход',
    category: ContentIconCategory.actions,
  ),
  ContentIconEntry(
    key: 'download',
    labelRu: 'Скачать',
    category: ContentIconCategory.actions,
  ),
  ContentIconEntry(
    key: 'upload',
    labelRu: 'Загрузить',
    category: ContentIconCategory.actions,
  ),
  ContentIconEntry(
    key: 'open_in_new',
    labelRu: 'Открыть',
    category: ContentIconCategory.actions,
  ),
  ContentIconEntry(
    key: 'link',
    labelRu: 'Ссылка',
    category: ContentIconCategory.actions,
  ),
  ContentIconEntry(
    key: 'work',
    labelRu: 'Работа / вакансии',
    category: ContentIconCategory.people,
  ),
  ContentIconEntry(
    key: 'groups',
    labelRu: 'Группа',
    category: ContentIconCategory.people,
  ),
  ContentIconEntry(
    key: 'person',
    labelRu: 'Профиль',
    category: ContentIconCategory.people,
  ),
  ContentIconEntry(
    key: 'school_outlined',
    labelRu: 'Колледж',
    category: ContentIconCategory.people,
  ),
  ContentIconEntry(
    key: 'emoji_events',
    labelRu: 'Достижение',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'star',
    labelRu: 'Избранное',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'favorite',
    labelRu: 'Лайк',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'lightbulb',
    labelRu: 'Идея',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'tips_and_updates',
    labelRu: 'Совет',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'campaign',
    labelRu: 'Объявление',
    category: ContentIconCategory.communication,
  ),
  ContentIconEntry(
    key: 'notifications',
    labelRu: 'Уведомления',
    category: ContentIconCategory.communication,
  ),
  ContentIconEntry(
    key: 'chat',
    labelRu: 'Чат',
    category: ContentIconCategory.communication,
  ),
  ContentIconEntry(
    key: 'forum',
    labelRu: 'Обсуждение',
    category: ContentIconCategory.communication,
  ),
  ContentIconEntry(
    key: 'image',
    labelRu: 'Изображение',
    category: ContentIconCategory.media,
  ),
  ContentIconEntry(
    key: 'photo_camera',
    labelRu: 'Фото',
    category: ContentIconCategory.media,
  ),
  ContentIconEntry(
    key: 'videocam',
    labelRu: 'Видео',
    category: ContentIconCategory.media,
  ),
  ContentIconEntry(
    key: 'play_circle',
    labelRu: 'Воспроизведение',
    category: ContentIconCategory.media,
  ),
  ContentIconEntry(
    key: 'headphones',
    labelRu: 'Аудио',
    category: ContentIconCategory.media,
  ),
  ContentIconEntry(
    key: 'article',
    labelRu: 'Статья',
    category: ContentIconCategory.media,
  ),
  ContentIconEntry(
    key: 'auto_awesome',
    labelRu: 'Акцент',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'verified',
    labelRu: 'Проверено',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'security',
    labelRu: 'Безопасность',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'health_and_safety',
    labelRu: 'Здоровье',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'support_agent',
    labelRu: 'Поддержка',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'contact_support',
    labelRu: 'Обратная связь',
    category: ContentIconCategory.help,
  ),
  ContentIconEntry(
    key: 'event',
    labelRu: 'Событие',
    category: ContentIconCategory.misc,
  ),
  ContentIconEntry(
    key: 'schedule',
    labelRu: 'Срок',
    category: ContentIconCategory.study,
  ),
  ContentIconEntry(
    key: 'bookmark',
    labelRu: 'Закладка',
    category: ContentIconCategory.misc,
  ),
];

/// Lookup catalog entry by key; null if unknown.
ContentIconEntry? contentIconEntryForKey(String? key) {
  if (key == null || key.isEmpty) return null;
  for (final entry in kContentIconCatalog) {
    if (entry.key == key) return entry;
  }
  return null;
}

/// Human-readable Russian label for a key (falls back to key itself).
String contentIconLabelRu(String? key) {
  return contentIconEntryForKey(key)?.labelRu ?? (key ?? '—');
}

/// Filter catalog entries by Russian label substring (case-insensitive).
List<ContentIconEntry> searchContentIconsByRuName(String query) {
  final trimmed = query.trim().toLowerCase();
  if (trimmed.isEmpty) return kContentIconCatalog;
  return kContentIconCatalog
      .where((e) => e.labelRu.toLowerCase().contains(trimmed))
      .toList();
}

/// List icons in a single category.
List<ContentIconEntry> listContentIconsByCategory(
  ContentIconCategory category,
) {
  return kContentIconCatalog.where((e) => e.category == category).toList();
}

/// Distinct categories present in the catalog (stable order).
List<ContentIconCategory> get contentIconCategories =>
    ContentIconCategory.values;
