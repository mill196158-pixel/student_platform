-- Rollback for Stage 2.1 dev/test seed.
-- Deletes ONLY rows marked by the Stage 2.1 test marker and exact test subjects/dates.
-- Do not use for production cleanup beyond this seed.

begin;

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
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
    and description like '%stage2_1_test_schedule_subject_link%'
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
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
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
    and description like '%stage2_1_test_schedule_subject_link%'
)
delete from public.team_members
where team_id in (select id from test_teams);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
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
    and description like '%stage2_1_test_schedule_subject_link%'
)
delete from public.chats
where team_id in (select id from test_teams)
   or subject_offering_id in (select id from test_offerings);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
),
test_offerings as (
  select id
  from public.subject_offerings
  where subject_id in (select id from test_subjects)
)
delete from public.teams
where subject_offering_id in (select id from test_offerings)
  and description like '%stage2_1_test_schedule_subject_link%';

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
),
test_offerings as (
  select id
  from public.subject_offerings
  where subject_id in (select id from test_subjects)
)
delete from public.lessons
where date in ('2026-06-19','2026-06-21')
  and subject_id in (select id from test_subjects)
  and subject_offering_id in (select id from test_offerings)
  and raw_subject_name in (
    'Тест 1 (сем.)',
    'Тест 2 (л.)',
    'Тест 1, практика Teams TEST-1',
    'Тест 2 (лаб.)',
    'Проверка 1 (сем.)',
    'Проверка 2 (л.)',
    'Проверка 1, практика Teams TEST-A',
    'Проверка 2 (лаб.)'
  );

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
)
delete from public.subject_aliases
where source = 'stage2_1_test_schedule_subject_link'
  and subject_id in (select id from test_subjects);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
)
delete from public.subject_offerings
where subject_id in (select id from test_subjects);

with test_subjects as (
  select id
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
)
delete from public.curriculum_subjects
where subject_id in (select id from test_subjects)
  and subject_index like 'STAGE2.1-TEST-%';

delete from public.subject_catalog
where description = 'stage2_1_test_schedule_subject_link'
  and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2');

commit;
