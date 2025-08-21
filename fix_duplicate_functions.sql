-- ========================================
-- ИСПРАВЛЕНИЕ ДУБЛИРУЮЩИХСЯ ФУНКЦИЙ
-- ========================================

-- 1. Удаляем ВСЕ существующие версии функций (включая 8-параметровую)
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text, text, uuid, text, uuid);
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text, text, uuid, text);
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text, text, uuid);
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text, text);
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text);

DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text, text, text, uuid, text, uuid, uuid);
DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text, text, text, uuid, text, uuid);
DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text, text, text, uuid, text);
DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text, text, text, uuid);
DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text, text);
DROP FUNCTION IF EXISTS public.send_chat_message_for_login(uuid, text);

-- 2. Проверяем, что все удалились
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

-- 3. Создаем ЕДИНСТВЕННУЮ правильную версию send_chat_message (из FAQ)
CREATE OR REPLACE FUNCTION public.send_chat_message(
  p_team_id uuid,
  p_text text,
  p_type text default 'text',
  p_reply_to uuid default null,
  p_attachment_url text default null,
  p_assignment_id uuid default null
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_chat_id uuid;
  v_author_id uuid;
  v_attachments jsonb;
BEGIN
  v_author_id := auth.uid();
  IF v_author_id IS NULL THEN
    RAISE EXCEPTION 'auth.uid() is null';
  END IF;

  SELECT id INTO v_chat_id FROM public.chats
  WHERE team_id = p_team_id AND type = 'team_main' LIMIT 1;

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'Chat not found for team %', p_team_id;
  END IF;

  IF p_attachment_url IS NULL OR length(trim(p_attachment_url)) = 0 THEN
    v_attachments := '[]'::jsonb;
  ELSE
    v_attachments := to_jsonb(array[p_attachment_url]);
  END IF;

  INSERT INTO public.messages(
    chat_id, author_id, content, body, msg_type, reply_to_id, attachments, assignment_id, created_at
  ) VALUES (
    v_chat_id, v_author_id, coalesce(p_text,''), coalesce(p_text,''),
    coalesce(p_type,'text'), p_reply_to, v_attachments, p_assignment_id, now()
  );
END; $$;

-- 4. Создаем ЕДИНСТВЕННУЮ правильную версию send_chat_message_for_login (из FAQ)
CREATE OR REPLACE FUNCTION public.send_chat_message_for_login(
  p_team_id uuid, 
  p_login text, 
  p_text text,
  p_type text default 'text',
  p_reply_to uuid default null,
  p_attachment_url text default null,
  p_assignment_id uuid default null
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_chat_id uuid;
  v_author_id uuid;
  v_attachments jsonb;
BEGIN
  SELECT id INTO v_author_id FROM public.users WHERE login = p_login LIMIT 1;
  IF v_author_id IS NULL THEN
    RAISE EXCEPTION 'User not found for login %', p_login;
  END IF;

  SELECT id INTO v_chat_id FROM public.chats
  WHERE team_id = p_team_id AND type = 'team_main' LIMIT 1;

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'Chat not found for team %', p_team_id;
  END IF;

  IF p_attachment_url IS NULL OR length(trim(p_attachment_url)) = 0 THEN
    v_attachments := '[]'::jsonb;
  ELSE
    v_attachments := to_jsonb(array[p_attachment_url]);
  END IF;

  INSERT INTO public.messages(
    chat_id, author_id, content, body, msg_type, reply_to_id, attachments, assignment_id, created_at
  ) VALUES (
    v_chat_id, v_author_id, coalesce(p_text,''), coalesce(p_text,''),
    coalesce(p_type,'text'), p_reply_to, v_attachments, p_assignment_id, now()
  );
END; $$;

-- 5. Даем права на выполнение
GRANT EXECUTE ON FUNCTION public.send_chat_message(uuid, text, text, uuid, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_chat_message_for_login(uuid, text, text, text, uuid, text, uuid) TO authenticated;

-- 6. Проверяем результат
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

-- 7. Показываем сигнатуры созданных функций
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname IN ('send_chat_message', 'send_chat_message_for_login')
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY p.proname;

SELECT '✅ Функции исправлены!' as status;
