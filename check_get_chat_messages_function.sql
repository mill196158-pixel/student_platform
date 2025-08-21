-- Проверяем функцию get_chat_messages_for_team
-- ========================================

-- 1. Проверяем функцию
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'get_chat_messages_for_team'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 2. Тестируем вызов функции для конкретной команды
-- Замените '7f0a7234-9565-4db4-9123-98c852740a6b' на реальный team_id
SELECT *
FROM get_chat_messages_for_team(
    p_team_id := '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid,
    p_limit := 5
);

-- 3. Проверяем последние сообщения с файлами в таблице messages
SELECT 
    id,
    body,
    msg_type,
    file_id,
    created_at
FROM messages 
WHERE file_id IS NOT NULL 
    AND chat_id IN (
        SELECT id FROM chats 
        WHERE team_id = '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid
    )
ORDER BY created_at DESC
LIMIT 5;
