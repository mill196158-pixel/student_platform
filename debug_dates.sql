-- ========================================
-- ДИАГНОСТИКА ПРОБЛЕМЫ С ДАТАМИ
-- ========================================

-- 1. Проверяем текущее время сервера
SELECT 
    'Текущее время сервера' as info,
    now() as server_time,
    now() AT TIME ZONE 'UTC' as server_time_utc,
    now() AT TIME ZONE 'Europe/Moscow' as server_time_msk;

-- 2. Последние 10 сообщений с датами
SELECT 
    m.id,
    m.content,
    m.created_at,
    m.created_at AT TIME ZONE 'UTC' as created_at_utc,
    m.created_at AT TIME ZONE 'Europe/Moscow' as created_at_msk,
    EXTRACT(EPOCH FROM (now() - m.created_at)) / 3600 as hours_ago,
    u.login as author
FROM public.messages m
LEFT JOIN public.users u ON u.id = m.author_id
ORDER BY m.created_at DESC
LIMIT 10;

-- 3. Проверяем, есть ли сообщения "сегодня"
SELECT 
    'Сообщения сегодня' as info,
    COUNT(*) as count
FROM public.messages m
WHERE DATE(m.created_at) = CURRENT_DATE;

-- 4. Проверяем, есть ли сообщения "вчера"
SELECT 
    'Сообщения вчера' as info,
    COUNT(*) as count
FROM public.messages m
WHERE DATE(m.created_at) = CURRENT_DATE - INTERVAL '1 day';

-- 5. Тестовое сообщение с текущим временем
SELECT public.send_chat_message_for_login(
  '7f0a7234-9565-4db4-9123-98c852740a6b'::uuid, -- team_id
  '13015',                                      -- login
  'Тест времени: ' || now()::text               -- text с текущим временем
);

-- 6. Проверяем созданное сообщение
SELECT 
    m.id,
    m.content,
    m.created_at,
    m.created_at AT TIME ZONE 'UTC' as created_at_utc,
    m.created_at AT TIME ZONE 'Europe/Moscow' as created_at_msk,
    EXTRACT(EPOCH FROM (now() - m.created_at)) as seconds_ago
FROM public.messages m
WHERE m.content LIKE '%Тест времени%'
ORDER BY m.created_at DESC
LIMIT 1;
