-- ========================================
-- ТЕСТОВЫЕ SQL ЗАПРОСЫ ДЛЯ ДИАГНОСТИКИ
-- ========================================

-- 1. Проверяем последние сообщения в чате
SELECT 
    m.id,
    m.content,
    m.msg_type,
    m.file_id,
    m.created_at,
    u.login as author,
    cf.file_name,
    cf.file_url
FROM messages m
LEFT JOIN users u ON m.author_id = u.id
LEFT JOIN chat_files cf ON m.file_id = cf.id
WHERE m.chat_id IN (
    SELECT id FROM chats WHERE type = 'team_main'
)
ORDER BY m.created_at DESC
LIMIT 10;

-- 2. Проверяем файлы в chat_files
SELECT 
    id,
    chat_id,
    message_id,
    file_name,
    file_key,
    file_url,
    file_type,
    file_size,
    uploaded_by,
    uploaded_at
FROM chat_files
ORDER BY uploaded_at DESC
LIMIT 10;

-- 3. Проверяем чаты
SELECT 
    id,
    team_id,
    type,
    created_at
FROM chats
WHERE type = 'team_main';

-- 4. Проверяем функции (должна быть только одна версия)
SELECT 
    routine_name,
    routine_definition
FROM information_schema.routines 
WHERE routine_name IN ('send_chat_message', 'send_chat_message_for_login')
AND routine_schema = 'public';

-- 5. Проверяем структуру таблицы messages
SELECT 
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns 
WHERE table_name = 'messages' 
AND table_schema = 'public'
ORDER BY ordinal_position;

-- 6. Проверяем структуру таблицы chat_files
SELECT 
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns 
WHERE table_name = 'chat_files' 
AND table_schema = 'public'
ORDER BY ordinal_position;

-- 7. Проверяем RLS политики
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies 
WHERE tablename IN ('messages', 'chat_files');

-- 8. Проверяем время сервера
SELECT NOW() as server_time, 
       CURRENT_TIMESTAMP as current_timestamp,
       timezone('UTC', NOW()) as utc_time;
