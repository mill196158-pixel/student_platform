-- ===========================================
-- ИСПРАВЛЕНИЕ RPC ФУНКЦИИ С ПРАВИЛЬНОЙ СВЯЗКОЙ ФАЙЛОВ
-- ===========================================

CREATE OR REPLACE FUNCTION public.send_chat_message_with_files(
  p_team_id uuid,
  p_text text DEFAULT '',
  p_type text DEFAULT 'text',
  p_file_ids uuid[] DEFAULT '{}'::uuid[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_chat_id uuid;
  v_message_id uuid;
  v_file_id uuid;
  v_user_id uuid;
BEGIN
  -- Проверяем аутентификацию
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Пользователь не аутентифицирован';
  END IF;

  -- Получаем chat_id для команды
  SELECT id INTO v_chat_id
  FROM public.chats
  WHERE team_id = p_team_id AND type = 'team_main'
  LIMIT 1;

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'Чат не найден для команды %', p_team_id;
  END IF;

  -- Создаем сообщение
  INSERT INTO public.messages (
    chat_id,
    author_id,
    content,
    body,
    msg_type,
    created_at
  ) VALUES (
    v_chat_id,
    v_user_id,
    p_text,
    p_text,
    p_type,
    now()
  ) RETURNING id INTO v_message_id;

  -- Связываем файлы с сообщением
  IF array_length(p_file_ids, 1) > 0 THEN
    -- Обновляем message_id в chat_files
    UPDATE public.chat_files
    SET message_id = v_message_id
    WHERE id = ANY(p_file_ids) AND uploaded_by = v_user_id;

    -- Добавляем файлы в attachments JSONB
    UPDATE public.messages
    SET attachments = (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', cf.id,
          'fileName', cf.file_name,
          'fileUrl', cf.file_url,
          'fileType', cf.file_type,
          'fileSize', cf.file_size,
          'uploadedAt', cf.uploaded_at
        )
      )
      FROM public.chat_files cf
      WHERE cf.message_id = v_message_id
    )
    WHERE id = v_message_id;
  END IF;

  RETURN v_message_id;
END;
$$
;

-- Даем права на выполнение
GRANT EXECUTE ON FUNCTION public.send_chat_message_with_files(uuid, text, text, uuid[]) TO authenticated;

