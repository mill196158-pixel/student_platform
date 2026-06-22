# 📁 Настройка файлового хранилища

## 🏗️ Архитектура

```
Flutter App → S3Client → Yandex Object Storage (файлы)
                ↓
            Supabase PostgreSQL (метаданные)
```

## 📋 Пошаговая настройка

### 1. Yandex Object Storage

#### Создание бакета:
1. Зайдите в [Yandex Cloud Console](https://console.cloud.yandex.ru/)
2. Выберите ваш проект
3. Перейдите в "Object Storage"
4. Создайте новый бакет:
   - **Имя**: `studentsplatform` (или любое другое)
   - **Регион**: `ru-central1`
   - **Тип доступа**: `Private` (приватный)

#### Создание сервисного аккаунта:
1. В Yandex Cloud Console перейдите в "Service Accounts"
2. Создайте новый сервисный аккаунт
3. Назначьте роль `storage.editor`
4. Создайте статический ключ доступа
5. **Сохраните**:
   - Access Key ID
   - Secret Access Key

### 2. Настройка Flutter приложения

#### Обновите `lib/src/config/yandex_storage_config.dart`:

```dart
class YandexStorageConfig {
  // Замените на ваши данные
  static const String _accessKey = 'YOUR_ACCESS_KEY'; // Ваш Access Key
  static const String _secretKey = 'YOUR_SECRET_KEY'; // Ваш Secret Key
  static const String _bucketName = 'YOUR_BUCKET_NAME'; // Имя вашего бакета
  static const String _region = 'ru-central1';
  static const String _endpoint = 'storage.yandexcloud.net';
  
  // ... остальной код без изменений
}
```

### 3. Настройка Supabase

#### Создание таблиц:
1. Зайдите в [Supabase Dashboard](https://supabase.com/dashboard)
2. Выберите ваш проект
3. Перейдите в "SQL Editor"
4. Скопируйте и выполните SQL код из файла `database_schema.sql`

#### Проверка таблиц:
После выполнения SQL должны появиться таблицы:
- `users`
- `teams` 
- `team_members`
- `chats`
- `messages`
- `files` ← **НОВАЯ**
- `assignments`
- `assignment_votes`
- `assignment_completions`

### 4. Тестирование

#### Запуск приложения:
```bash
flutter run
```

#### Тест подключения:
1. Откройте чат в приложении
2. Нажмите "⋮" (три точки) в верхнем правом углу
3. Выберите "Тест файлового сервиса"
4. Нажмите "Тест подключения"

#### Тест загрузки файла:
1. В тестовом экране нажмите "Загрузить тестовый файл"
2. Выберите любой файл
3. Проверьте результат

## 🔧 Возможные проблемы

### Ошибка "Bucket not found":
- Проверьте имя бакета в `YandexStorageConfig`
- Убедитесь, что бакет создан в правильном регионе

### Ошибка "Access Denied":
- Проверьте Access Key и Secret Key
- Убедитесь, что сервисный аккаунт имеет роль `storage.editor`

### Ошибка "SignatureDoesNotMatch":
- Проверьте правильность ключей
- Убедитесь, что время на устройстве синхронизировано

## 📁 Структура файлов в Yandex Storage

```
studentsplatform/
├── chats/
│   ├── {chatId}/
│   │   ├── documents/
│   │   │   ├── 1755722634572.pdf
│   │   │   ├── 1755722634573.docx
│   │   │   └── 1755722634574.dwg
│   │   ├── images/
│   │   │   ├── 1755722634575.jpg
│   │   │   └── 1755722634576.png
│   │   ├── archives/
│   │   │   └── 1755722634577.zip
│   │   └── other/
│   │       └── 1755722634578.txt
│   └── {anotherChatId}/
│       └── ...
└── test/
    └── connection-test.txt
```

## 🔒 Безопасность

### RLS (Row Level Security):
- Пользователи видят только файлы в своих командах
- Загружать файлы можно только в чаты своих команд
- Удалять можно только свои файлы

### Доступ к файлам:
- Файлы хранятся в приватном бакете
- Доступ через подписанные URL (если нужно)
- Метаданные в Supabase с RLS

## 📊 Мониторинг

### Логи в Yandex Cloud:
- Cloud Logging → Object Storage
- Отслеживание запросов и ошибок

### Логи в Supabase:
- Dashboard → Logs
- Отслеживание SQL запросов

## 🚀 Следующие шаги

После успешного тестирования:

1. **Интеграция в чат**:
   - Добавить кнопку загрузки файлов
   - Отображение файлов как сообщений
   - Скачивание и открытие файлов

2. **Оптимизация**:
   - Сжатие изображений
   - Предварительный просмотр
   - Прогресс загрузки

3. **Дополнительные функции**:
   - Поиск файлов
   - Фильтрация по типу
   - Статистика использования

## 💰 Стоимость

### Yandex Object Storage:
- ~0.5₽ за ГБ в месяц
- ~0.5₽ за 1000 запросов

### Supabase:
- Бесплатный план: 500MB база данных
- Платный план: от $25/месяц

## 📞 Поддержка

При возникновении проблем:
1. Проверьте логи в консоли Flutter
2. Проверьте логи в Yandex Cloud Console
3. Проверьте логи в Supabase Dashboard
4. Создайте issue с описанием ошибки
