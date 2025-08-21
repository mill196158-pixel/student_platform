-- ========================================
-- ИСПРАВЛЕНИЕ СТРУКТУРЫ CHAT_FILES
-- ========================================

-- 1. Разрешаем NULL в колонке message_id
ALTER TABLE chat_files
ALTER COLUMN message_id DROP NOT NULL;

-- 2. Проверяем структуру таблицы
SELECT 
    column_name,
    is_nullable,
    data_type,
    column_default
FROM information_schema.columns
WHERE table_name = 'chat_files'
ORDER BY ordinal_position;

-- 3. Проверяем существующие записи с пустыми message_id
SELECT 
    COUNT(*) as total_files,
    COUNT(CASE WHEN message_id IS NULL THEN 1 END) as files_without_message,
    COUNT(CASE WHEN message_id = '' THEN 1 END) as files_with_empty_message
FROM chat_files;

-- 4. Обновляем пустые строки на NULL
UPDATE chat_files 
SET message_id = NULL 
WHERE message_id = '';

-- 5. Проверяем результат
SELECT 
    COUNT(*) as total_files,
    COUNT(CASE WHEN message_id IS NULL THEN 1 END) as files_without_message
FROM chat_files;

-- ========================================
-- СОЗДАНИЕ ФУНКЦИИ СВЯЗЫВАНИЯ ФАЙЛОВ
-- ========================================

-- Функция для связывания файла с сообщением
CREATE OR REPLACE FUNCTION public.link_chat_file_to_message(
  p_file_id uuid,
  p_message_id uuid
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Обновляем message_id для файла
  UPDATE public.chat_files
  SET message_id = p_message_id
  WHERE id = p_file_id;
  
  -- Возвращаем true если обновление прошло успешно
  RETURN FOUND;
END; $$;

-- Даем права на выполнение
GRANT EXECUTE ON FUNCTION public.link_chat_file_to_message(uuid, uuid) TO authenticated;

-- Проверяем создание функции
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'link_chat_file_to_message'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');

-- ========================================
-- ПРОВЕРКА РЕЗУЛЬТАТА
-- ========================================

SELECT '✅ Структура chat_files исправлена!' as status;

-- Показываем финальную структуру
SELECT 
    column_name,
    is_nullable,
    data_type
FROM information_schema.columns
WHERE table_name = 'chat_files'
ORDER BY ordinal_position;
