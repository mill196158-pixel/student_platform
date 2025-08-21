-- ========================================
-- БЫСТРЫЙ ТЕСТ ДЛЯ ПРОВЕРКИ ПРОБЛЕМЫ
-- ========================================

-- 1. Проверяем текущего пользователя
SELECT 
    'Current user' as test,
    auth.uid() as user_id,
    CASE 
        WHEN auth.uid() IS NOT NULL THEN '✅ Authenticated'
        ELSE '❌ Not authenticated'
    END as status;

-- 2. Проверяем доступные команды для текущего пользователя
SELECT 
    'Available teams' as test,
    tm.team_id,
    tm.role,
    t.name as team_name
FROM team_members tm
JOIN teams t ON t.id = tm.team_id
WHERE tm.user_id = auth.uid()
LIMIT 5;

-- 3. Проверяем чаты для доступных команд
SELECT 
    'Available chats' as test,
    c.id as chat_id,
    c.team_id,
    c.type,
    t.name as team_name
FROM chats c
JOIN teams t ON t.id = c.team_id
JOIN team_members tm ON tm.team_id = c.team_id
WHERE tm.user_id = auth.uid()
AND c.type = 'team_main'
LIMIT 5;

-- 4. Тестируем функцию send_chat_message с реальными данными
DO $$
DECLARE
    v_team_id UUID;
    v_chat_id UUID;
    v_result UUID;
    v_error TEXT;
BEGIN
    -- Получаем первую доступную команду
    SELECT tm.team_id INTO v_team_id
    FROM team_members tm
    WHERE tm.user_id = auth.uid()
    LIMIT 1;
    
    IF v_team_id IS NULL THEN
        RAISE NOTICE '❌ No teams found for current user';
        RETURN;
    END IF;
    
    -- Получаем chat_id для команды
    SELECT c.id INTO v_chat_id
    FROM chats c
    WHERE c.team_id = v_team_id AND c.type = 'team_main'
    LIMIT 1;
    
    IF v_chat_id IS NULL THEN
        RAISE NOTICE '❌ No team_main chat found for team %', v_team_id;
        RETURN;
    END IF;
    
    RAISE NOTICE '🔍 Testing with team_id: %, chat_id: %', v_team_id, v_chat_id;
    
    -- Тестируем функцию
    BEGIN
        SELECT send_chat_message(v_team_id, 'Test message from diagnostic', 'text') INTO v_result;
        RAISE NOTICE '✅ send_chat_message SUCCESS! Returned message_id: %', v_result;
        
        -- Проверяем, что сообщение создалось
        IF EXISTS (SELECT 1 FROM messages WHERE id = v_result) THEN
            RAISE NOTICE '✅ Message confirmed in database';
        ELSE
            RAISE NOTICE '⚠️ Message not found in database';
        END IF;
        
    EXCEPTION 
        WHEN OTHERS THEN
            v_error := SQLERRM;
            RAISE NOTICE '❌ send_chat_message ERROR: %', v_error;
            
            -- Дополнительная диагностика
            IF v_error LIKE '%User not authenticated%' THEN
                RAISE NOTICE '💡 Issue: User authentication problem';
            ELSIF v_error LIKE '%Chat not found%' THEN
                RAISE NOTICE '💡 Issue: Chat not found for team';
            ELSIF v_error LIKE '%permission%' THEN
                RAISE NOTICE '💡 Issue: RLS policy violation';
            ELSE
                RAISE NOTICE '💡 Issue: Unknown error';
            END IF;
    END;
END $$;

-- 5. Проверяем RLS политики для messages
SELECT 
    'Messages RLS policies' as test,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM pg_policies 
WHERE tablename = 'messages';

-- 6. Проверяем последние сообщения
SELECT 
    'Recent messages' as test,
    id,
    chat_id,
    author_id,
    content,
    msg_type,
    type,
    created_at
FROM messages 
ORDER BY created_at DESC
LIMIT 3;
