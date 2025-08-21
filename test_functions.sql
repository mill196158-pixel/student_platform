-- ========================================
-- ТЕСТ ФУНКЦИЙ ПОСЛЕ ИСПРАВЛЕНИЯ
-- ========================================

-- 1. Проверяем количество версий функций
SELECT 
    'send_chat_message' as function_name,
    COUNT(*) as versions_count
FROM pg_proc 
WHERE proname = 'send_chat_message' 
    AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
UNION ALL
SELECT 
    'send_chat_message_for_login' as function_name,
    COUNT(*) as versions_count
FROM pg_proc 
WHERE proname = 'send_chat_message_for_login' 
    AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- 2. Показываем сигнатуры функций
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname IN ('send_chat_message', 'send_chat_message_for_login')
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY p.proname;

-- 3. Тестируем функцию send_chat_message_for_login
SELECT public.send_chat_message_for_login(
  '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid, -- team_id
  '13015',                                      -- login
  'Тест после исправления функций 🚀'            -- text
);

-- 4. Проверяем, что сообщение появилось
SELECT 
    m.id,
    m.created_at,
    u.login as author_login,
    m.content,
    m.msg_type
FROM public.messages m
LEFT JOIN public.users u ON u.id = m.author_id
WHERE m.content LIKE '%Тест после исправления функций%'
ORDER BY m.created_at DESC
LIMIT 5;
