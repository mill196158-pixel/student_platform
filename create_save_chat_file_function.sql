-- ========================================
-- СОЗДАНИЕ ФУНКЦИИ SAVE_CHAT_FILE
-- ========================================

-- Создаем функцию для сохранения файла в chat_files
CREATE OR REPLACE FUNCTION public.save_chat_file(
  p_chat_id uuid,
  p_file_name text,
  p_file_key text,
  p_file_url text,
  p_file_type text,
  p_file_size bigint,
  p_uploaded_by uuid,
  p_message_id uuid default null
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_file_id uuid;
BEGIN
  -- Вставляем файл и получаем его ID
  INSERT INTO public.chat_files(
    chat_id,
    message_id,
    file_name,
    file_key,
    file_url,
    file_type,
    file_size,
    uploaded_by,
    uploaded_at
  ) VALUES (
    p_chat_id,
    p_message_id,
    p_file_name,
    p_file_key,
    p_file_url,
    p_file_type,
    p_file_size,
    p_uploaded_by,
    now()
  ) RETURNING id INTO v_file_id;

  RETURN v_file_id;
END; $$;

-- Даем права на выполнение
GRANT EXECUTE ON FUNCTION public.save_chat_file(uuid, text, text, text, text, bigint, uuid, uuid) TO authenticated;

-- Проверяем создание функции
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'save_chat_file'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

SELECT '✅ Функция save_chat_file создана!' as status;
