-- Исправляем все версии функции get_chat_messages_for_team
-- ========================================

-- 1. Удаляем все версии функции
DROP FUNCTION IF EXISTS get_chat_messages_for_team(uuid);
DROP FUNCTION IF EXISTS get_chat_messages_for_team(uuid, integer);
DROP FUNCTION IF EXISTS get_chat_messages_for_team(uuid, integer, timestamp with time zone);

-- 2. Создаем правильную версию с file_id и всеми параметрами
CREATE OR REPLACE FUNCTION get_chat_messages_for_team(
    p_team_id uuid,
    p_limit integer DEFAULT 400,
    p_since timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone
)
RETURNS TABLE(
    id uuid, 
    chat_id uuid, 
    author_id uuid, 
    author_login text, 
    author_name text, 
    author_avatar_url text, 
    content text, 
    body text, 
    created_at timestamp with time zone, 
    reply_to_id uuid, 
    type text, 
    assignment_id uuid, 
    file_id uuid,
    attachments jsonb, 
    is_pinned boolean
) AS $$
BEGIN
  RETURN QUERY
  WITH main_chat AS (
    SELECT id
    FROM public.chats
    WHERE team_id = p_team_id AND type = 'team_main'
    LIMIT 1
  )
  SELECT 
    m.id,
    m.chat_id,
    m.author_id,
    u.login AS author_login,
    trim(coalesce(u.name,'') || ' ' || coalesce(u.surname,'')) AS author_name,
    u.avatar_url AS author_avatar_url,
    m.content,
    m.body,
    m.created_at,
    m.reply_to_id,
    coalesce(m.type, m.msg_type, 'text') AS type,
    m.assignment_id,
    m.file_id,
    coalesce(m.attachments, '[]'::jsonb) AS attachments,
    coalesce(m.is_pinned, false) AS is_pinned
  FROM public.messages m
  JOIN main_chat c ON c.id = m.chat_id
  LEFT JOIN public.users u ON u.id = m.author_id
  WHERE m.created_at > p_since
  ORDER BY m.created_at ASC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Проверяем, что функция создана
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'get_chat_messages_for_team'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
