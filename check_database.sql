-- ========================================
-- ДИАГНОСТИКА ПРОБЛЕМЫ С ФАЙЛАМИ
-- ========================================

-- 1. Проверяем структуру таблицы messages
SELECT 
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_name = 'messages'
ORDER BY ordinal_position;

-- 2. Проверяем, есть ли колонка file_id в messages
SELECT 
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns 
WHERE table_name = 'messages' 
    AND column_name = 'file_id';

-- 3. Проверяем последние сообщения с файлами
SELECT 
    id,
    text,
    type,
    file_id,
    created_at
FROM messages 
WHERE type = 'file' OR file_id IS NOT NULL
ORDER BY created_at DESC
LIMIT 10;

-- 4. Проверяем таблицу chat_files
SELECT 
    id,
    chat_id,
    message_id,
    file_name,
    file_type,
    file_url,
    uploaded_at,
    is_deleted
FROM chat_files 
ORDER BY uploaded_at DESC
LIMIT 10;

-- 5. Проверяем связь между messages и chat_files
SELECT 
    m.id as message_id,
    m.text as message_text,
    m.type as message_type,
    m.file_id,
    cf.id as chat_file_id,
    cf.file_name,
    cf.file_type,
    cf.file_url,
    cf.message_id as chat_file_message_id
FROM messages m
LEFT JOIN chat_files cf ON m.file_id = cf.id
WHERE m.type = 'file' OR m.file_id IS NOT NULL
ORDER BY m.created_at DESC
LIMIT 10;

-- 6. Проверяем функции
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname IN ('send_chat_message', 'save_chat_file', 'link_chat_file_to_message')
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 7. Проверяем права доступа
SELECT 
    grantee,
    table_name,
    privilege_type
FROM information_schema.role_table_grants
WHERE table_name IN ('messages', 'chat_files')
    AND grantee = 'authenticated';

-- 8. Проверяем RLS политики
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM pg_policies
WHERE tablename IN ('messages', 'chat_files');
