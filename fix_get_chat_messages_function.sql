-- Исправляем функцию get_chat_messages_for_team для возврата file_id
-- ========================================

-- Получаем текущее определение функции
SELECT 
    p.proname as function_name,
    pg_get_functiondef(p.oid) as function_definition
FROM pg_proc p
WHERE p.proname = 'get_chat_messages_for_team'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
LIMIT 1;

-- Проверяем, есть ли file_id в таблице messages
SELECT 
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns 
WHERE table_name = 'messages' 
    AND column_name = 'file_id';
