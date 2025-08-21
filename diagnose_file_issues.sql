-- ========================================
-- ДИАГНОСТИКА ПРОБЛЕМ С ФАЙЛАМИ (БЕЗОПАСНО)
-- ========================================

-- 1. Проверяем текущее ограничение типа сообщений
SELECT 
    conname as constraint_name,
    pg_get_constraintdef(oid) as constraint_definition
FROM pg_constraint 
WHERE conname = 'messages_msg_type_check';

-- 2. Проверяем существующие функции send_chat_message
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname IN ('send_chat_message', 'send_chat_message_for_login')
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY p.proname, pg_get_function_arguments(p.oid);

-- 3. Проверяем последние сообщения с файлами
SELECT 
    id,
    body,
    msg_type,
    file_id,
    created_at,
    author_id
FROM messages 
WHERE file_id IS NOT NULL OR msg_type = 'file'
ORDER BY created_at DESC
LIMIT 20;

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
LIMIT 20;

-- 5. Проверяем связь между messages и chat_files
SELECT 
    m.id as message_id,
    m.body as message_text,
    m.msg_type as message_type,
    m.file_id as message_file_id,
    cf.id as chat_file_id,
    cf.file_name,
    cf.file_type,
    cf.file_url,
    cf.message_id as chat_file_message_id
FROM messages m
LEFT JOIN chat_files cf ON m.file_id = cf.id
WHERE m.file_id IS NOT NULL OR m.msg_type = 'file'
ORDER BY m.created_at DESC
LIMIT 20;

-- 6. Проверяем структуру таблицы messages
SELECT 
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_name = 'messages' 
    AND column_name IN ('msg_type', 'file_id')
ORDER BY ordinal_position;

-- 7. Проверяем права доступа к таблицам
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
    cmd
FROM pg_policies
WHERE tablename IN ('messages', 'chat_files');
