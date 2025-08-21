-- Проверяем существующую функцию link_chat_file_to_message
-- ========================================

-- 1. Проверяем все версии функции
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type,
    p.oid as function_oid
FROM pg_proc p
WHERE p.proname = 'link_chat_file_to_message'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 2. Получаем исходный код функции
SELECT 
    p.proname as function_name,
    pg_get_functiondef(p.oid) as function_definition
FROM pg_proc p
WHERE p.proname = 'link_chat_file_to_message'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
LIMIT 1;

-- 3. Проверяем, используется ли функция в коде
SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes 
WHERE indexdef LIKE '%link_chat_file_to_message%';

-- 4. Проверяем зависимости
SELECT 
    dependent_ns.nspname as dependent_schema,
    dependent_proc.proname as dependent_function
FROM pg_depend d
JOIN pg_proc dependent_proc ON d.refobjid = dependent_proc.oid
JOIN pg_namespace dependent_ns ON dependent_proc.pronamespace = dependent_ns.oid
JOIN pg_proc target_proc ON d.objid = target_proc.oid
WHERE target_proc.proname = 'link_chat_file_to_message'
    AND target_proc.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
