-- ========================================
-- ПРОВЕРКА ФУНКЦИЙ ОТПРАВКИ СООБЩЕНИЙ
-- ========================================

-- 1. Проверяем существование функций
SELECT 
    'send_chat_message' as function_name,
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'send_chat_message') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END as status
UNION ALL
SELECT 
    'send_chat_message_for_login',
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'send_chat_message_for_login') 
        THEN '✅ EXISTS' 
        ELSE '❌ MISSING' 
    END;

-- 2. Проверяем сигнатуры функций
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname IN ('send_chat_message', 'send_chat_message_for_login')
ORDER BY p.proname;

-- 3. Проверяем права на функции
SELECT 
    p.proname as function_name,
    p.proacl as permissions
FROM pg_proc p
WHERE p.proname IN ('send_chat_message', 'send_chat_message_for_login')
ORDER BY p.proname;

-- 4. Тестируем функцию send_chat_message (если есть данные)
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
            -- Пытаемся вызвать функцию
            SELECT send_chat_message(v_team_id, 'Test message from SQL', 'text') INTO v_result;
            RAISE NOTICE '✅ send_chat_message test: SUCCESS, returned: %', v_result;
        EXCEPTION 
            WHEN OTHERS THEN
                RAISE NOTICE '❌ send_chat_message test: ERROR - %', SQLERRM;
        END;
    ELSE
        RAISE NOTICE '⚠️ No team_main chats found for testing';
    END IF;
END $$;

-- 5. Проверяем последние сообщения
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
