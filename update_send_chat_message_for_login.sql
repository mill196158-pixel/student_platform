-- Обновляем функцию send_chat_message_for_login для поддержки file_id
-- ========================================

-- 1. Удаляем старую функцию
DROP FUNCTION IF EXISTS send_chat_message_for_login(
    p_team_id uuid,
    p_login text,
    p_text text,
    p_type text,
    p_reply_to uuid,
    p_attachment_url text,
    p_assignment_id uuid
);

-- 2. Создаем новую функцию с поддержкой file_id
CREATE OR REPLACE FUNCTION send_chat_message_for_login(
    p_team_id uuid,
    p_login text,
    p_text text,
    p_type text DEFAULT 'text',
    p_reply_to uuid DEFAULT NULL,
    p_attachment_url text DEFAULT NULL,
    p_assignment_id uuid DEFAULT NULL,
    p_file_id uuid DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
    v_chat_id uuid;
    v_user_id uuid;
    v_message_id uuid;
BEGIN
    -- Получаем chat_id для команды
    SELECT id INTO v_chat_id
    FROM chats
    WHERE team_id = p_team_id AND type = 'team_main'
    LIMIT 1;
    
    IF v_chat_id IS NULL THEN
        RAISE EXCEPTION 'Chat not found for team %', p_team_id;
    END IF;
    
    -- Получаем user_id по логину
    SELECT id INTO v_user_id
    FROM users
    WHERE login = p_login
    LIMIT 1;
    
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not found with login %', p_login;
    END IF;
    
    -- Создаем сообщение
    INSERT INTO messages (
        chat_id,
        author_id,
        body,
        msg_type,
        reply_to_id,
        attachment_url,
        assignment_id,
        file_id,
        created_at
    ) VALUES (
        v_chat_id,
        v_user_id,
        p_text,
        p_type,
        p_reply_to,
        p_attachment_url,
        p_assignment_id,
        p_file_id,
        NOW()
    ) RETURNING id INTO v_message_id;
    
    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Проверяем, что функция создана
SELECT 
    p.proname as function_name,
    pg_get_function_arguments(p.oid) as arguments,
    pg_get_function_result(p.oid) as return_type
FROM pg_proc p
WHERE p.proname = 'send_chat_message_for_login'
    AND p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
