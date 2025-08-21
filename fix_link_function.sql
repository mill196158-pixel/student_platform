-- Исправляем существующую функцию link_chat_file_to_message
-- ========================================

-- Обновляем функцию, добавляя недостающую логику
CREATE OR REPLACE FUNCTION link_chat_file_to_message(
    p_file_id uuid,
    p_message_id uuid
) RETURNS boolean AS $$
BEGIN
    -- Обновляем chat_files, устанавливая message_id (существующая логика)
    UPDATE chat_files
    SET message_id = p_message_id
    WHERE id = p_file_id;

    -- ДОБАВЛЯЕМ: Обновляем messages, устанавливая file_id (недостающая логика)
    UPDATE messages 
    SET file_id = p_file_id
    WHERE id = p_message_id;

    -- Возвращаем результат (сохраняем существующую логику)
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Проверяем, что функция обновлена
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'link_chat_file_to_message'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
