-- Создание таблицы chat_files для хранения информации о файлах в чате
CREATE TABLE IF NOT EXISTS chat_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    file_name TEXT NOT NULL,
    file_key TEXT NOT NULL, -- Ключ в Yandex Storage
    file_url TEXT NOT NULL, -- URL для скачивания
    file_type TEXT NOT NULL, -- MIME тип
    file_size INTEGER NOT NULL, -- Размер в байтах
    uploaded_by UUID NOT NULL REFERENCES users(id),
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_deleted BOOLEAN DEFAULT FALSE,
    
    -- Индексы для быстрого поиска
    INDEX idx_chat_files_chat_id (chat_id),
    INDEX idx_chat_files_message_id (message_id),
    INDEX idx_chat_files_uploaded_by (uploaded_by),
    INDEX idx_chat_files_file_type (file_type)
);

-- RLS политики для chat_files
ALTER TABLE chat_files ENABLE ROW LEVEL SECURITY;

-- Пользователи могут видеть файлы в чатах, где они участники
CREATE POLICY "Users can view files in their team chats" ON chat_files
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE c.id = chat_files.chat_id
            AND tm.user_id = auth.uid()
        )
    );

-- Пользователи могут загружать файлы в чаты, где они участники
CREATE POLICY "Users can upload files to their team chats" ON chat_files
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE c.id = chat_files.chat_id
            AND tm.user_id = auth.uid()
        )
        AND uploaded_by = auth.uid()
    );

-- Пользователи могут удалять свои файлы
CREATE POLICY "Users can delete their own files" ON chat_files
    FOR UPDATE USING (uploaded_by = auth.uid())
    WITH CHECK (uploaded_by = auth.uid());

-- Функция для сохранения файла в chat_files
CREATE OR REPLACE FUNCTION save_chat_file(
    p_chat_id UUID,
    p_message_id UUID,
    p_file_name TEXT,
    p_file_key TEXT,
    p_file_url TEXT,
    p_file_type TEXT,
    p_file_size INTEGER,
    p_uploaded_by UUID
) RETURNS UUID AS $$
DECLARE
    v_file_id UUID;
BEGIN
    -- Проверяем, что пользователь является участником команды
    IF NOT EXISTS (
        SELECT 1 FROM team_members tm
        JOIN chats c ON c.team_id = tm.team_id
        WHERE c.id = p_chat_id
        AND tm.user_id = p_uploaded_by
    ) THEN
        RAISE EXCEPTION 'User is not a member of this team';
    END IF;

    -- Вставляем запись о файле
    INSERT INTO chat_files (
        chat_id,
        message_id,
        file_name,
        file_key,
        file_url,
        file_type,
        file_size,
        uploaded_by
    ) VALUES (
        p_chat_id,
        p_message_id,
        p_file_name,
        p_file_key,
        p_file_url,
        p_file_type,
        p_file_size,
        p_uploaded_by
    ) RETURNING id INTO v_file_id;

    RETURN v_file_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Обновляем функцию send_chat_message для поддержки file_id
CREATE OR REPLACE FUNCTION send_chat_message(
    p_team_id UUID,
    p_text TEXT,
    p_type TEXT DEFAULT 'text',
    p_reply_to UUID DEFAULT NULL,
    p_attachment_url TEXT DEFAULT NULL,
    p_assignment_id UUID DEFAULT NULL,
    p_file_id UUID DEFAULT NULL
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
        assignment_id,
        file_id
    ) VALUES (
        v_chat_id,
        v_user_id,
        p_text,
        p_text,
        p_type,
        p_type,
        p_reply_to,
        p_attachment_url,
        p_assignment_id,
        p_file_id
    ) RETURNING id INTO v_message_id;

    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Обновляем функцию send_chat_message_for_login для поддержки file_id
CREATE OR REPLACE FUNCTION send_chat_message_for_login(
    p_team_id UUID,
    p_login TEXT,
    p_text TEXT,
    p_type TEXT DEFAULT 'text',
    p_reply_to UUID DEFAULT NULL,
    p_attachment_url TEXT DEFAULT NULL,
    p_assignment_id UUID DEFAULT NULL,
    p_file_id UUID DEFAULT NULL
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
        assignment_id,
        file_id
    ) VALUES (
        v_chat_id,
        v_user_id,
        p_text,
        p_text,
        p_type,
        p_type,
        p_reply_to,
        p_attachment_url,
        p_assignment_id,
        p_file_id
    ) RETURNING id INTO v_message_id;

    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
