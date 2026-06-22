# 🔧 ИСПРАВЛЕНИЯ CHAT_TAB.DART

## ❌ ПРОБЛЕМЫ:

1. **Старая логика поиска файлов** - ищет по `fileId`, а не по `attachments`
2. **Пустые URL** - файлы не загружаются из Yandex Storage
3. **Дублирование логики** - старая система `_chatFiles` + новая `attachments`
4. **Потеря связи** - `fileId=null` в сообщениях

## ✅ РЕШЕНИЕ:

### 1. УДАЛИТЬ СТАРУЮ ЛОГИКУ
```dart
// УДАЛИТЬ:
final List<ChatFile> _chatFiles = [];
Future<void> _loadChatFiles() async { ... }
Future<Map<String, List<ChatFile>>> _loadFilesForMessages() async { ... }
```

### 2. ИСПОЛЬЗОВАТЬ ТОЛЬКО ATTACHMENTS
```dart
// В MessageBubble уже передается:
attachments: m.attachments, // ✅ УЖЕ РАБОТАЕТ!

// MultiFileBubble получает:
List<ChatFile> attachments // ✅ УЖЕ ГОТОВ!
```

### 3. ИСПРАВИТЬ ЛОГИКУ ОТОБРАЖЕНИЯ
```dart
// ЗАМЕНИТЬ старую логику:
if (m.type == MessageType.file) {
  // Старый код поиска по fileId
}

// НА новую логику:
if (m.attachments != null && m.attachments!.isNotEmpty) {
  if (m.attachments!.length == 1) {
    // Одиночный файл - FileMessageBubble
  } else {
    // Множественные файлы - MultiFileBubble
  }
} else {
  // Обычное текстовое сообщение
}
```

### 4. ИСПРАВИТЬ ЗАГРУЗКУ ФАЙЛОВ
```dart
// В _uploadFileToChat добавить:
// 1. Загрузка в Yandex Storage
// 2. Сохранение в chat_files
// 3. Связывание с сообщением через message_id
```

## 🎯 ПЛАН ДЕЙСТВИЙ:

1. **Удалить старую логику** `_chatFiles` и `_loadChatFiles`
2. **Переписать логику отображения** для использования `m.attachments`
3. **Исправить загрузку файлов** в Yandex Storage
4. **Протестировать** отображение файлов

## 📋 КЛЮЧЕВЫЕ ИЗМЕНЕНИЯ:

### В _buildMessagesWithDates:
```dart
// Вместо проверки m.type == MessageType.file
if (m.attachments != null && m.attachments!.isNotEmpty) {
  if (m.attachments!.length == 1) {
    // FileMessageBubble для одиночного файла
    widgets.add(FileMessageBubble(file: m.attachments!.first, ...));
  } else {
    // MultiFileBubble для множественных файлов
    widgets.add(MultiFileBubble(files: m.attachments!, ...));
  }
} else {
  // Обычное текстовое сообщение
  widgets.add(MessageBubble(...));
}
```

### В _uploadFileToChat:
```dart
// 1. Загрузить в Yandex Storage
// 2. Сохранить в chat_files с message_id = null
// 3. Создать сообщение
// 4. Связать файл с сообщением через link_chat_file_to_message
```







