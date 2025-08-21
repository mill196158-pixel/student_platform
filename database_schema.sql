-- SQL схема для Supabase PostgreSQL
-- Создание таблиц для файлового хранилища

-- Включение расширений
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Таблица пользователей (если еще не создана)
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email VARCHAR(255) UNIQUE NOT NULL,
    full_name VARCHAR(255),
    avatar_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Таблица команд (если еще не создана)
CREATE TABLE IF NOT EXISTS teams (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Таблица участников команд (если еще не создана)
CREATE TABLE IF NOT EXISTS team_members (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role VARCHAR(50) DEFAULT 'member', -- 'admin', 'member'
    joined_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(team_id, user_id)
);

-- Таблица чатов (если еще не создана)
CREATE TABLE IF NOT EXISTS chats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    name VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Таблица сообщений (если еще не создана)
CREATE TABLE IF NOT EXISTS messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content TEXT,
    message_type VARCHAR(50) DEFAULT 'text', -- 'text', 'file', 'assignment', 'poll'
    reply_to_id UUID REFERENCES messages(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Таблица файлов (НОВАЯ)
CREATE TABLE IF NOT EXISTS files (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    message_id UUID REFERENCES messages(id) ON DELETE CASCADE,
    chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    uploaded_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    file_key VARCHAR(500) NOT NULL, -- Ключ в Yandex Object Storage
    original_name VARCHAR(255) NOT NULL,
    file_type VARCHAR(50) NOT NULL, -- 'documents', 'images', 'archives', 'videos', 'audio', 'other'
    mime_type VARCHAR(100) NOT NULL,
    file_size BIGINT NOT NULL,
    file_url TEXT NOT NULL,
    thumbnail_url TEXT, -- Для изображений
    is_deleted BOOLEAN DEFAULT false,
    deleted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Таблица заданий (если еще не создана)
CREATE TABLE IF NOT EXISTS assignments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    chat_id UUID NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    link TEXT,
    due_date VARCHAR(50), -- Формат: DD.MM
    status VARCHAR(50) DEFAULT 'draft', -- 'draft', 'published', 'completed'
    is_pinned BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Таблица голосов за задания (если еще не создана)
CREATE TABLE IF NOT EXISTS assignment_votes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    assignment_id UUID NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    vote_type VARCHAR(20) NOT NULL, -- 'up', 'down'
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(assignment_id, user_id)
);

-- Таблица выполненных заданий (если еще не создана)
CREATE TABLE IF NOT EXISTS assignment_completions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    assignment_id UUID NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    completed_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(assignment_id, completed_by)
);

-- Индексы для оптимизации
CREATE INDEX IF NOT EXISTS idx_files_chat_id ON files(chat_id);
CREATE INDEX IF NOT EXISTS idx_files_uploaded_by ON files(uploaded_by);
CREATE INDEX IF NOT EXISTS idx_files_file_type ON files(file_type);
CREATE INDEX IF NOT EXISTS idx_files_created_at ON files(created_at);
CREATE INDEX IF NOT EXISTS idx_files_file_key ON files(file_key);

CREATE INDEX IF NOT EXISTS idx_messages_chat_id ON messages(chat_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);

CREATE INDEX IF NOT EXISTS idx_assignments_chat_id ON assignments(chat_id);
CREATE INDEX IF NOT EXISTS idx_assignments_created_by ON assignments(created_by);
CREATE INDEX IF NOT EXISTS idx_assignments_status ON assignments(status);

-- Триггеры для обновления updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_teams_updated_at BEFORE UPDATE ON teams FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_chats_updated_at BEFORE UPDATE ON chats FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_messages_updated_at BEFORE UPDATE ON messages FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_assignments_updated_at BEFORE UPDATE ON assignments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS (Row Level Security) политики
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE teams ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE files ENABLE ROW LEVEL SECURITY;
ALTER TABLE assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE assignment_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE assignment_completions ENABLE ROW LEVEL SECURITY;

-- Политики для файлов
CREATE POLICY "Users can view files in their teams" ON files
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE tm.user_id = auth.uid() AND c.id = files.chat_id
        )
    );

CREATE POLICY "Users can upload files to their teams" ON files
    FOR INSERT WITH CHECK (
        uploaded_by = auth.uid() AND
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE tm.user_id = auth.uid() AND c.id = files.chat_id
        )
    );

CREATE POLICY "Users can delete their own files" ON files
    FOR UPDATE USING (uploaded_by = auth.uid());

-- Политики для сообщений
CREATE POLICY "Users can view messages in their teams" ON messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE tm.user_id = auth.uid() AND c.id = messages.chat_id
        )
    );

CREATE POLICY "Users can send messages to their teams" ON messages
    FOR INSERT WITH CHECK (
        sender_id = auth.uid() AND
        EXISTS (
            SELECT 1 FROM team_members tm
            JOIN chats c ON c.team_id = tm.team_id
            WHERE tm.user_id = auth.uid() AND c.id = messages.chat_id
        )
    );

-- Функции для работы с файлами
CREATE OR REPLACE FUNCTION get_chat_files(chat_uuid UUID)
RETURNS TABLE (
    id UUID,
    file_key VARCHAR(500),
    original_name VARCHAR(255),
    file_type VARCHAR(50),
    mime_type VARCHAR(100),
    file_size BIGINT,
    file_url TEXT,
    thumbnail_url TEXT,
    uploaded_by UUID,
    created_at TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        f.id,
        f.file_key,
        f.original_name,
        f.file_type,
        f.mime_type,
        f.file_size,
        f.file_url,
        f.thumbnail_url,
        f.uploaded_by,
        f.created_at
    FROM files f
    WHERE f.chat_id = chat_uuid 
    AND f.is_deleted = false
    ORDER BY f.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION get_chat_files_by_type(chat_uuid UUID, file_type_filter VARCHAR(50))
RETURNS TABLE (
    id UUID,
    file_key VARCHAR(500),
    original_name VARCHAR(255),
    file_type VARCHAR(50),
    mime_type VARCHAR(100),
    file_size BIGINT,
    file_url TEXT,
    thumbnail_url TEXT,
    uploaded_by UUID,
    created_at TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        f.id,
        f.file_key,
        f.original_name,
        f.file_type,
        f.mime_type,
        f.file_size,
        f.file_url,
        f.thumbnail_url,
        f.uploaded_by,
        f.created_at
    FROM files f
    WHERE f.chat_id = chat_uuid 
    AND f.file_type = file_type_filter
    AND f.is_deleted = false
    ORDER BY f.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

