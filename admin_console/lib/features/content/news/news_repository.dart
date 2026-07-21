import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'news_item.dart';

/// News persistence boundary for the admin console.
///
/// Stage 12.0 uses an in-memory mock. Publish remains unavailable until
/// Supabase Auth/RBAC/Storage is ready.
abstract class NewsRepository {
  Future<List<NewsItem>> loadDraft();

  Future<void> saveDraft(List<NewsItem> items);

  /// Intentionally unsupported in the local prototype.
  Future<void> publish(List<NewsItem> items);
}

class LocalNewsRepository implements NewsRepository {
  List<NewsItem> _items = [
    const NewsItem(
      id: 1,
      title: 'Добро пожаловать в новый семестр',
      subtitle: 'Всё важное для спокойного старта учёбы',
      variant: StudentHomeNewsVariant.gradientText,
      colors: [Color(0xFF7367F0), Color(0xFFB784F7)],
    ),
    const NewsItem(
      id: 2,
      title: 'Неделя студенческих инициатив',
      subtitle: 'Выбирайте событие и присоединяйтесь',
      variant: StudentHomeNewsVariant.imageOverlay,
      colors: [Color(0xFF246B8E), Color(0xFF54B7AD)],
      overlayDarken: 0.48,
    ),
    const NewsItem(
      id: 3,
      title: 'Новые материалы по предметам',
      subtitle: 'Методички уже доступны в разделе «Полезная»',
      variant: StudentHomeNewsVariant.imageWithText,
      colors: [Color(0xFFF3A95F), Color(0xFFE66E75)],
    ),
    const NewsItem(
      id: 4,
      title: 'Студенческий кампус',
      subtitle: 'Фотогалерея июльских событий',
      variant: StudentHomeNewsVariant.imageOnly,
      colors: [Color(0xFF4158D0), Color(0xFFC850C0)],
    ),
  ];

  DateTime? lastSavedAt;

  @override
  Future<List<NewsItem>> loadDraft() async {
    return List<NewsItem>.from(_items);
  }

  @override
  Future<void> saveDraft(List<NewsItem> items) async {
    _items = List<NewsItem>.from(items);
    lastSavedAt = DateTime.now();
  }

  @override
  Future<void> publish(List<NewsItem> items) async {
    throw UnsupportedError(
      'Публикация недоступна до подключения безопасного доступа.',
    );
  }
}
