-- Создаем функцию link_chat_file_to_message
-- ========================================

CREATE OR REPLACE FUNCTION link_chat_file_to_message(
    p_file_id uuid,
    p_message_id uuid
) RETURNS void AS $$
BEGIN
    -- Обновляем chat_files, устанавливая message_id
    UPDATE chat_files 
    SET message_id = p_message_id
    WHERE id = p_file_id;
    
    -- Обновляем messages, устанавливая file_id
    UPDATE messages 
    SET file_id = p_file_id
    WHERE id = p_message_id;
    
    -- Проверяем, что обновления прошли успешно
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Failed to link file % to message %', p_file_id, p_message_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Проверяем, что функция создана
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'link_chat_file_to_message'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
