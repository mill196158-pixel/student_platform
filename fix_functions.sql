-- Удаляем все версии функций send_chat_message
DROP FUNCTION IF EXISTS send_chat_message(uuid, text, text, uuid, text, uuid);
DROP FUNCTION IF EXISTS send_chat_message(uuid, text, text, uuid, text);
DROP FUNCTION IF EXISTS send_chat_message(uuid, text);

-- Удаляем все версии функций send_chat_message_for_login  
DROP FUNCTION IF EXISTS send_chat_message_for_login(uuid, text, text, text, uuid, text, uuid);
DROP FUNCTION IF EXISTS send_chat_message_for_login(uuid, text, text, text, uuid, text);
DROP FUNCTION IF EXISTS send_chat_message_for_login(uuid, text, text);

-- Пересоздаем ПРАВИЛЬНЫЕ функции (без file_id)
CREATE OR REPLACE FUNCTION send_chat_message(
    p_team_id UUID,
    p_text TEXT,
    p_type TEXT DEFAULT 'text',
    p_reply_to UUID DEFAULT NULL,
    p_attachment_url TEXT DEFAULT NULL,
    p_assignment_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_chat_id UUID;
    v_message_id UUID;
    v_user_id UUID;
BEGIN
    -- Получаем ID пользователя
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User not authenticated';
    END IF;

    -- Получаем chat_id для команды
    SELECT id INTO v_chat_id
    FROM chats
    WHERE team_id = p_team_id AND type = 'team_main'
    LIMIT 1;

    IF v_chat_id IS NULL THEN
        RAISE EXCEPTION 'Chat not found for team %', p_team_id;
    END IF;

    -- Вставляем сообщение
    INSERT INTO messages (
        chat_id,
        author_id,
        content,
        body,
        msg_type,
        type,
        reply_to_id,
        attachment_url,
        assignment_id
    ) VALUES (
        v_chat_id,
        v_user_id,
        p_text,
        p_text,
        p_type,
        p_type,
        p_reply_to,
        p_attachment_url,
        p_assignment_id
    ) RETURNING id INTO v_message_id;

    -- Файлы связываются с сообщениями через chat_files.message_id
    -- Это делается на уровне Flutter после создания сообщения

    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Пересоздаем функцию для логина
CREATE OR REPLACE FUNCTION send_chat_message_for_login(
    p_team_id UUID,
    p_login TEXT,
    p_text TEXT,
    p_type TEXT DEFAULT 'text',
    p_reply_to UUID DEFAULT NULL,
    p_attachment_url TEXT DEFAULT NULL,
    p_assignment_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    v_chat_id UUID;
    v_message_id UUID;
    v_user_id UUID;
BEGIN
    -- Получаем user_id по логину
    SELECT id INTO v_user_id
    FROM users
    WHERE login = p_login
    LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User with login % not found', p_login;
    END IF;

    -- Получаем chat_id для команды
    SELECT id INTO v_chat_id
    FROM chats
    WHERE team_id = p_team_id AND type = 'team_main'
    LIMIT 1;

    IF v_chat_id IS NULL THEN
        RAISE EXCEPTION 'Chat not found for team %', p_team_id;
    END IF;

    -- Вставляем сообщение
    INSERT INTO messages (
        chat_id,
        author_id,
        content,
        body,
        msg_type,
        type,
        reply_to_id,
        attachment_url,
        assignment_id
    ) VALUES (
        v_chat_id,
        v_user_id,
        p_text,
        p_text,
        p_type,
        p_type,
        p_reply_to,
        p_attachment_url,
        p_assignment_id
    ) RETURNING id INTO v_message_id;

    -- Файлы связываются с сообщениями через chat_files.message_id
    -- Это делается на уровне Flutter после создания сообщения

    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
