# 📁 Документация файлового сервера Student Platform

## 🏗️ Архитектура системы

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   Flutter App   │───▶│  Supabase DB     │    │  Yandex Object      │
│                 │    │  (PostgreSQL)    │    │  Storage            │
│ - UI Components │    │ - Метаданные     │    │ - Файлы             │
│ - File Upload   │    │ - Связи          │    │ - Бинарные данные   │
│ - File Display  │    │ - RLS политики   │    │ - Структура папок   │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
```

## 📊 Структура базы данных

### Таблица `messages`
```sql
CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id UUID NOT NULL,
    author_id UUID NOT NULL,
    body TEXT NOT NULL,
    msg_type TEXT NOT NULL CHECK (msg_type IN ('text', 'assignmentDraft', 'assignmentPublished', 'file')),
    reply_to_id UUID,
    attachment_url TEXT,
    assignment_id UUID,
    file_id UUID,  -- ← СВЯЗЬ С ФАЙЛАМИ
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_pinned BOOLEAN DEFAULT FALSE
);
```

### Таблица `chat_files`
```sql
CREATE TABLE chat_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id UUID NOT NULL,
    message_id UUID,  -- ← СВЯЗЬ С СООБЩЕНИЯМИ
    file_name TEXT NOT NULL,
    file_url TEXT NOT NULL,
    file_type TEXT NOT NULL,
    file_size BIGINT NOT NULL,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
```

## 🔗 Связи между таблицами

```
messages.file_id ──▶ chat_files.id
chat_files.message_id ──▶ messages.id
```

**Двусторонняя связь:**
- Сообщение знает, какой файл к нему прикреплен
- Файл знает, в каком сообщении он используется

## 🚀 Процесс загрузки файла

### 1. Выбор файла пользователем
```dart
// Пользователь нажимает скрепку в чате
// Выбирает файл через FilePicker
File? file = await FilePicker.platform.pickFiles();
```

### 2. Создание записи в `chat_files`
```dart
// Создается запись с message_id = null
ChatFile chatFile = ChatFile(
    id: '', // Будет заполнено после сохранения
    chatId: chatId,
    messageId: null, // Пока сообщение не создано
    fileName: file.name,
    fileUrl: '', // Будет заполнено после загрузки
    fileType: file.extension,
    fileSize: file.size,
);
```

### 3. Загрузка в Yandex Object Storage
```dart
// Файл загружается в структуру:
// chats/{chatId}/{fileType}/{timestamp}.{extension}
String fileKey = "chats/$chatId/$fileType/$timestamp.$extension";

// Загрузка через MinIO клиент
await minioClient.putObject(
    bucketName,
    fileKey,
    fileStream,
    fileSize,
    contentType: fileType
);
```

### 4. Обновление записи в `chat_files`
```dart
// Обновляется URL файла
chatFile = chatFile.copyWith(
    fileUrl: "https://bucket.storage.yandexcloud.net/$fileKey"
);
```

### 5. Создание сообщения
```dart
// Создается сообщение с типом 'file'
Message message = Message(
    id: '', // Будет заполнено
    chatId: chatId,
    authorId: userId,
    body: "📎 ${file.name}",
    msgType: MessageType.file,
    fileId: null, // Пока не связан
);
```

### 6. Связывание файла с сообщением
```dart
// Вызывается функция link_chat_file_to_message
await supabase.rpc('link_chat_file_to_message', params: {
    'p_file_id': chatFile.id,
    'p_message_id': message.id
});
```

## 📁 Структура файлов в Yandex Storage

```
studentsplatform/
├── chats/
│   ├── bbcd8727-1a1b-45d7-a162-aa74269f0eee/  # ID чата
│   │   ├── documents/
│   │   │   ├── 1755788392926.pdf
│   │   │   ├── 1755788392927.docx
│   │   │   └── 1755788392928.dwg
│   │   ├── images/
│   │   │   ├── 1755788392929.jpg
│   │   │   ├── 1755788392930.png
│   │   │   └── 1755788392931.jpeg
│   │   ├── archives/
│   │   │   └── 1755788392932.zip
│   │   └── other/
│   │       └── 1755788392933.txt
│   └── another-chat-id/
│       └── ...
└── test/
    └── connection-test.txt
```

## 🔧 Ключевые функции базы данных

### 1. `link_chat_file_to_message`
```sql
CREATE OR REPLACE FUNCTION link_chat_file_to_message(
    p_file_id uuid,
    p_message_id uuid
) RETURNS boolean AS $$
BEGIN
    -- Обновляем chat_files, устанавливая message_id
    UPDATE chat_files 
    SET message_id = p_message_id
    WHERE id = p_file_id;
    
    -- Обновляем messages, устанавливая file_id
    UPDATE messages 
    SET file_id = p_file_id
    WHERE id = p_message_id;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 2. `get_chat_messages_for_team`
```sql
CREATE OR REPLACE FUNCTION get_chat_messages_for_team(
    p_team_id uuid,
    p_limit integer DEFAULT 400,
    p_since timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'
)
RETURNS TABLE(
    id uuid, 
    chat_id uuid, 
    author_id uuid, 
    author_login text, 
    author_name text, 
    author_avatar_url text, 
    content text, 
    body text, 
    created_at timestamp with time zone, 
    reply_to_id uuid, 
    type text, 
    assignment_id uuid, 
    file_id uuid,  -- ← ВОЗВРАЩАЕТ file_id
    attachments jsonb, 
    is_pinned boolean
) AS $$
-- ... SQL код ...
```

## 🎨 Отображение файлов в UI

### FileMessageBubble
```dart
class FileMessageBubble extends StatelessWidget {
  final ChatFile file;
  final bool isOwnMessage;
  
  @override
  Widget build(BuildContext context) {
    if (file.isImage) {
      // Показываем превью изображения
      return ImagePreview(file: file);
    } else {
      // Показываем карточку файла
      return FileCard(file: file);
    }
  }
}
```

### Типы отображения:
1. **Изображения**: Превью + возможность открыть в полном размере
2. **Документы**: Иконка типа файла + название + размер
3. **Архивы**: Иконка архива + название + размер
4. **Другие**: Универсальная иконка + название + размер

## 🔒 Безопасность

### Row Level Security (RLS)
```sql
-- Пользователи видят только файлы в своих командах
CREATE POLICY "Users can view files in their teams" ON chat_files
    FOR SELECT USING (
        chat_id IN (
            SELECT c.id FROM chats c
            JOIN team_members tm ON c.team_id = tm.team_id
            WHERE tm.user_id = auth.uid()
        )
    );

-- Загружать файлы можно только в чаты своих команд
CREATE POLICY "Users can upload files to their team chats" ON chat_files
    FOR INSERT WITH CHECK (
        chat_id IN (
            SELECT c.id FROM chats c
            JOIN team_members tm ON c.team_id = tm.team_id
            WHERE tm.user_id = auth.uid()
        )
    );
```

### Доступ к файлам:
- **Приватный бакет**: Файлы недоступны напрямую
- **Подписанные URL**: Временный доступ при необходимости
- **Метаданные в Supabase**: Контролируемый доступ через RLS

## 📊 Мониторинг и логирование

### Логи в приложении:
```dart
print('✅ Файл успешно загружен!');
print('🔗 URL: $fileUrl');
print('📁 Размер: $fileSize байт');
print('🎨 Тип: $fileType');
```

### Логи в Yandex Cloud:
- Cloud Logging → Object Storage
- Отслеживание запросов и ошибок
- Мониторинг использования

### Логи в Supabase:
- Dashboard → Logs
- Отслеживание SQL запросов
- Мониторинг RLS политик

## 🔧 Конфигурация

### Yandex Storage Config
```dart
class YandexStorageConfig {
  static const String _accessKey = 'YOUR_ACCESS_KEY';
  static const String _secretKey = 'YOUR_SECRET_KEY';
  static const String _bucketName = 'YOUR_BUCKET_NAME';
  static const String _region = 'ru-central1';
  static const String _endpoint = 'storage.yandexcloud.net';
}
```

### Поддерживаемые типы файлов:
- **Изображения**: jpg, jpeg, png, gif, webp
- **Документы**: pdf, doc, docx, txt, rtf
- **Чертежи**: dwg, dxf
- **Архивы**: zip, rar, 7z
- **Другие**: Все остальные типы

## 🚀 Производительность

### Оптимизации:
1. **Сжатие изображений**: Автоматическое сжатие больших изображений
2. **Кэширование**: Локальное кэширование превью
3. **Прогресс загрузки**: Отображение прогресса для больших файлов
4. **Ленивая загрузка**: Загрузка превью по требованию

### Ограничения:
- **Максимальный размер файла**: 100MB
- **Максимальное количество файлов**: 1000 на чат
- **Поддерживаемые форматы**: Все стандартные форматы

## 💰 Стоимость

### Yandex Object Storage:
- **Хранение**: ~0.5₽ за ГБ в месяц
- **Запросы**: ~0.5₽ за 1000 запросов
- **Трафик**: ~0.5₽ за ГБ исходящего трафика

### Supabase:
- **База данных**: Бесплатно до 500MB
- **Хранилище**: Бесплатно до 1GB
- **Запросы**: Бесплатно до 50,000 запросов/месяц

## 🐛 Отладка проблем

### Частые проблемы:

1. **Файл не отображается**:
   - Проверить `file_id` в сообщении
   - Проверить связь в `chat_files`
   - Проверить URL файла

2. **Ошибка загрузки**:
   - Проверить ключи Yandex Storage
   - Проверить права доступа к бакету
   - Проверить размер файла

3. **Файл исчезает после перезахода**:
   - Проверить функцию `get_chat_messages_for_team`
   - Проверить возврат `file_id`
   - Проверить связывание файлов

### Команды для диагностики:
```sql
-- Проверить сообщения с файлами
SELECT * FROM messages WHERE msg_type = 'file' ORDER BY created_at DESC LIMIT 5;

-- Проверить файлы в чате
SELECT * FROM chat_files WHERE chat_id = 'chat-id' ORDER BY uploaded_at DESC;

-- Проверить связь файлов и сообщений
SELECT m.id, m.body, cf.file_name, cf.file_url 
FROM messages m 
JOIN chat_files cf ON m.file_id = cf.id 
WHERE m.msg_type = 'file';
```

## 📈 Статистика использования

### Метрики для отслеживания:
- Количество загруженных файлов
- Общий объем хранилища
- Популярные типы файлов
- Активность по командам

### Аналитика:
```sql
-- Статистика по типам файлов
SELECT 
    file_type,
    COUNT(*) as count,
    SUM(file_size) as total_size
FROM chat_files 
GROUP BY file_type 
ORDER BY count DESC;

-- Статистика по командам
SELECT 
    t.name as team_name,
    COUNT(cf.id) as files_count,
    SUM(cf.file_size) as total_size
FROM chat_files cf
JOIN chats c ON cf.chat_id = c.id
JOIN teams t ON c.team_id = t.id
GROUP BY t.id, t.name
ORDER BY files_count DESC;
```

---

**Версия документации**: 1.0  
**Дата обновления**: 21.08.2025  
**Автор**: AI Assistant  
**Статус**: Активная разработка

