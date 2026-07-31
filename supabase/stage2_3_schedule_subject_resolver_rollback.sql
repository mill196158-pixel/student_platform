-- Rollback for Stage 2.3 schedule subject resolver/linker test seed.
-- Deletes ONLY Stage 2.3 test subjects/offerings/lessons/teams/chats and drops
-- functions created by `stage2_3_schedule_subject_resolver.sql`.
-- Does not touch Stage 2.1 subjects: Тест 1, Тест 2, Проверка 1, Проверка 2.

begin;

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
)
delete from public.lessons
where date = '2026-06-23'
  and (
    subject in (
      'Тест парсинга пары (сем.)',
      'Тест парсинга пары, практика Teams PARSE-1',
      'Проверка парсинга пары (сем.)',
      'Проверка парсинга пары, практика Teams PARSE-A'
    )
    or raw_subject_name in (
      'Тест парсинга пары (сем.)',
      'Тест парсинга пары, практика Teams PARSE-1',
      'Проверка парсинга пары (сем.)',
      'Проверка парсинга пары, практика Teams PARSE-A'
    )
    or subject_id in (select id from test_subjects)
  );

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
),
test_offerings as (
  select id
  from public.subject_offerings
  where subject_id in (select id from test_subjects)
),
test_teams as (
  select id
  from public.teams
  where subject_offering_id in (select id from test_offerings)
    and description like '%stage2_3_schedule_subject_resolver%'
),
test_chats as (
  select id
  from public.chats
  where team_id in (select id from test_teams)
     or subject_offering_id in (select id from test_offerings)
)
delete from public.chat_members
where chat_id in (select id from test_chats);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
),
test_offerings as (
  select id
  from public.subject_offerings
  where subject_id in (select id from test_subjects)
),
test_teams as (
  select id
  from public.teams
  where subject_offering_id in (select id from test_offerings)
    and description like '%stage2_3_schedule_subject_resolver%'
)
delete from public.team_members
where team_id in (select id from test_teams);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
),
test_offerings as (
  select id
  from public.subject_offerings
  where subject_id in (select id from test_subjects)
),
test_teams as (
  select id
  from public.teams
  where subject_offering_id in (select id from test_offerings)
    and description like '%stage2_3_schedule_subject_resolver%'
)
delete from public.chats
where team_id in (select id from test_teams)
   or subject_offering_id in (select id from test_offerings);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
),
test_offerings as (
  select id
  from public.subject_offerings
  where subject_id in (select id from test_subjects)
)
delete from public.teams
where subject_offering_id in (select id from test_offerings)
  and description like '%stage2_3_schedule_subject_resolver%';

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
)
delete from public.subject_aliases
where source = 'stage2_3_schedule_subject_resolver'
  and subject_id in (select id from test_subjects);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
)
delete from public.subject_offerings
where subject_id in (select id from test_subjects);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_3_schedule_subject_resolver'
    and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары')
)
delete from public.curriculum_subjects
where subject_id in (select id from test_subjects)
  and subject_index like 'STAGE2.3-TEST-%';

delete from public.subject_catalog
where description = 'stage2_3_schedule_subject_resolver'
  and canonical_name in ('Тест парсинга пары', 'Проверка парсинга пары');

drop function if exists public.link_lesson_subject_from_schedule(uuid);
drop function if exists public.resolve_subject_offering_for_schedule(uuid, text, date, integer);
drop function if exists public.f_norm_schedule_subject(text);

commit;
