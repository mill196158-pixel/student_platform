-- ========================================
-- ДИАГНОСТИЧЕСКИЙ СКРИПТ ДЛЯ ПРОВЕРКИ ФАЙЛОВ
-- ========================================

-- 1. Проверяем существование таблицы chat_files
SELECT 
    'chat_files table' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'chat_files') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 2. Проверяем структуру таблицы chat_files
SELECT 
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns 
WHERE table_name = 'chat_files' 
ORDER BY ordinal_position;

-- 3. Проверяем индексы chat_files
SELECT 
    indexname,
    indexdef
FROM pg_indexes 
WHERE tablename = 'chat_files';

-- 4. Проверяем RLS политики chat_files
SELECT 
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies 
WHERE tablename = 'chat_files';

-- 5. Проверяем существование функции save_chat_file
SELECT 
    'save_chat_file function' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'save_chat_file') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 6. Проверяем сигнатуру функции save_chat_file
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'save_chat_file';

-- 7. Проверяем существование функции send_chat_message
SELECT 
    'send_chat_message function' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'send_chat_message') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 8. Проверяем сигнатуру функции send_chat_message
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'send_chat_message';

-- 9. Проверяем существование функции send_chat_message_for_login
SELECT 
    'send_chat_message_for_login function' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'send_chat_message_for_login') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 10. Проверяем сигнатуру функции send_chat_message_for_login
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'send_chat_message_for_login';

-- 11. Проверяем существование таблицы chats
SELECT 
    'chats table' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'chats') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 12. Проверяем существование таблицы messages
SELECT 
    'messages table' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'messages') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 13. Проверяем существование таблицы team_members
SELECT 
    'team_members table' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'team_members') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 14. Проверяем существование таблицы users
SELECT 
    'users table' as component,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'users') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status;

-- 15. Проверяем данные в таблице chats (первые 5 записей)
SELECT 
    'Sample chats data' as component,
    COUNT(*) as total_chats
FROM chats;

SELECT 
    id,
    team_id,
    type,
    created_at
FROM chats 
LIMIT 5;

-- 16. Проверяем данные в таблице team_members (первые 5 записей)
SELECT 
    'Sample team_members data' as component,
    COUNT(*) as total_members
FROM team_members;

SELECT 
    team_id,
    user_id,
    role,
    created_at
FROM team_members 
LIMIT 5;

-- 17. Проверяем данные в таблице users (первые 5 записей)
SELECT 
    'Sample users data' as component,
    COUNT(*) as total_users
FROM users;

SELECT 
    id,
    login,
    name,
    surname,
    created_at
FROM users 
LIMIT 5;

-- 18. Проверяем данные в таблице messages (первые 5 записей)
SELECT 
    'Sample messages data' as component,
    COUNT(*) as total_messages
FROM messages;

SELECT 
    id,
    chat_id,
    author_id,
    content,
    msg_type,
    type,
    created_at
FROM messages 
ORDER BY created_at DESC
LIMIT 5;

-- 19. Проверяем данные в таблице chat_files (если есть)
SELECT 
    'Sample chat_files data' as component,
    COUNT(*) as total_files
FROM chat_files;

SELECT 
    id,
    chat_id,
    message_id,
    file_name,
    file_type,
    file_size,
    uploaded_by,
    uploaded_at
FROM chat_files 
ORDER BY uploaded_at DESC
LIMIT 5;

-- 20. Тестируем функцию send_chat_message (если есть данные)
DO $$
DECLARE
    v_team_id UUID;
    v_result UUID;
BEGIN
    -- Получаем первый team_id из chats
    SELECT team_id INTO v_team_id 
    FROM chats 
    WHERE type = 'team_main' 
    LIMIT 1;
    
    IF v_team_id IS NOT NULL THEN
        BEGIN
            -- Пытаемся вызвать функцию (это может не сработать без авторизации)
            SELECT send_chat_message(v_team_id, 'Test message', 'text') INTO v_result;
            RAISE NOTICE '✅ send_chat_message test: SUCCESS, returned: %', v_result;
        EXCEPTION 
            WHEN OTHERS THEN
                RAISE NOTICE '⚠️ send_chat_message test: ERROR - %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE '⚠️ No team_main chats found for testing';
    END IF;
END $$;

-- 21. Итоговая сводка
SELECT 
    '=== DIAGNOSTIC SUMMARY ===' as summary,
    'Check the results above for any ❌ MISSING components' as recommendation;
