-- ========================================
-- ПРОВЕРКА ФУНКЦИИ get_chat_messages_for_team
-- ========================================

-- 1. Проверяем функцию get_chat_messages_for_team
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'get_chat_messages_for_team'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 2. Проверяем, что функция возвращает file_id
-- (Это нужно проверить вручную, посмотрев на код функции)

-- 3. Тестируем вызов функции для конкретной команды
-- Замените '7f0a7234-9565-4db4-9123-98c852740a6b' на реальный team_id
SELECT * FROM get_chat_messages_for_team(
    p_team_id := '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid,
    p_limit := 10
) LIMIT 5;

-- 4. Проверяем, есть ли сообщения с file_id в базе
SELECT 
    COUNT(*) as total_messages,
    COUNT(CASE WHEN file_id IS NOT NULL THEN 1 END) as messages_with_file_id,
    COUNT(CASE WHEN msg_type = 'file' THEN 1 END) as messages_with_file_type
FROM messages 
WHERE chat_id IN (
    SELECT id FROM chats 
    WHERE team_id = '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid
);

-- 5. Проверяем последние сообщения в чате
SELECT 
    m.id,
    m.body,
    m.msg_type,
    m.file_id,
    m.created_at,
    cf.file_name,
    cf.file_url
FROM messages m
LEFT JOIN chat_files cf ON m.file_id = cf.id
WHERE m.chat_id IN (
    SELECT id FROM chats 
    WHERE team_id = '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid
)
ORDER BY m.created_at DESC
LIMIT 10;
