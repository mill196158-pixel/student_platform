-- Проверяем функцию link_chat_file_to_message
-- ========================================

-- 1. Проверяем функцию
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'link_chat_file_to_message'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 2. Проверяем последние файлы в chat_files
SELECT 
    id,
    file_name,
    file_url,
    message_id,
    uploaded_at
FROM chat_files 
WHERE chat_id IN (
    SELECT id FROM chats 
    WHERE team_id = '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid
)
ORDER BY uploaded_at DESC
LIMIT 5;

-- 3. Проверяем последние сообщения с типом 'file'
SELECT 
    id,
    body,
    msg_type,
    file_id,
    created_at
FROM messages 
WHERE msg_type = 'file'
    AND chat_id IN (
        SELECT id FROM chats 
        WHERE team_id = '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid
    )
ORDER BY created_at DESC
LIMIT 5;
