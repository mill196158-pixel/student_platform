-- Исправляем ограничение типа сообщений для поддержки файлов
-- ========================================

-- 1. Удаляем старое ограничение
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_msg_type_check;

-- 2. Создаем новое ограничение с поддержкой 'file'
ALTER TABLE messages ADD CONSTRAINT messages_msg_type_check 
CHECK (msg_type IN ('text', 'assignmentDraft', 'assignmentPublished', 'file'));

-- 3. Проверяем, что ограничение создано
SELECT 
    conname as constraint_name,
    pg_get_constraintdef(oid) as constraint_definition
FROM pg_constraint 
WHERE conname = 'messages_msg_type_check';

-- 4. Проверяем существующие сообщения с типом 'file'
SELECT 
    id,
    body,
    msg_type,
    file_id,
    created_at
FROM messages 
WHERE msg_type = 'file'
ORDER BY created_at DESC
LIMIT 10;
