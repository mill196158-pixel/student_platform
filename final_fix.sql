-- ========================================
-- ИТОГОВЫЙ СКРИПТ ДЛЯ ИСПРАВЛЕНИЯ ФАЙЛОВ
-- ========================================

-- 1. Создаем таблицу chat_files (если не существует)
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
    is_deleted BOOLEAN DEFAULT FALSE
);

-- 2. Создаем индексы
CREATE INDEX IF NOT EXISTS idx_chat_files_chat_id ON chat_files(chat_id);
CREATE INDEX IF NOT EXISTS idx_chat_files_message_id ON chat_files(message_id);
CREATE INDEX IF NOT EXISTS idx_chat_files_uploaded_by ON chat_files(uploaded_by);
CREATE INDEX IF NOT EXISTS idx_chat_files_file_type ON chat_files(file_type);

-- 3. Включаем RLS
ALTER TABLE chat_files ENABLE ROW LEVEL SECURITY;

-- 4. Удаляем старые политики (если есть)
DROP POLICY IF EXISTS "Users can view files in their team chats" ON chat_files;
DROP POLICY IF EXISTS "Users can upload files to their team chats" ON chat_files;
DROP POLICY IF EXISTS "Users can delete their own files" ON chat_files;

-- 5. Создаем новые RLS политики
CREATE POLICY "Users can view files in their team chats" ON chat_files
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE c.id = chat_files.chat_id
            AND tm.user_id = auth.uid()
        )
    );

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

CREATE POLICY "Users can delete their own files" ON chat_files
    FOR UPDATE USING (uploaded_by = auth.uid())
    WITH CHECK (uploaded_by = auth.uid());

-- 6. Удаляем старые функции
DROP FUNCTION IF EXISTS save_chat_file(UUID, UUID, TEXT, TEXT, TEXT, TEXT, INTEGER, UUID);

-- 7. Создаем функцию save_chat_file
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

-- 8. Удаляем старые функции send_chat_message
DROP FUNCTION IF EXISTS send_chat_message(uuid, text, text, uuid, text, uuid);
DROP FUNCTION IF EXISTS send_chat_message(uuid, text, text, uuid, text);
DROP FUNCTION IF EXISTS send_chat_message(uuid, text);

-- 9. Удаляем старые функции send_chat_message_for_login
DROP FUNCTION IF EXISTS send_chat_message_for_login(uuid, text, text, text, uuid, text, uuid);
DROP FUNCTION IF EXISTS send_chat_message_for_login(uuid, text, text, text, uuid, text);
DROP FUNCTION IF EXISTS send_chat_message_for_login(uuid, text, text);

-- 10. Создаем правильные функции send_chat_message
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

    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 11. Создаем функцию send_chat_message_for_login
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

    RETURN v_message_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 12. Проверяем результат
SELECT '✅ Все функции созданы успешно!' as status;
