-- Read-only post-check after approved VV 2024 current-semester teams creation.
-- This file intentionally contains SELECT statements only.

-- 1. Summary for current semester teams/chats/members.
with current_offerings as (
  select
    so.id as subject_offering_id,
    so.group_id,
    g.name as group_name,
    so.subject_id,
    so.display_name,
    so.semester_number
  from public.subject_offerings so
  join public.groups g on g.id = so.group_id
  where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
    and so.semester_number = 4
),
current_teams as (
  select
    co.*,
    t.id as team_id,
    t.name as team_name,
    t.group_name as team_group_name
  from current_offerings co
  left join public.teams t on t.subject_offering_id = co.subject_offering_id
),
current_chats as (
  select
    ct.*,
    ch.id as chat_id
  from current_teams ct
  left join public.chats ch
    on ch.team_id = ct.team_id
   and ch.type = 'team_main'
),
expected_members as (
  select
    ct.team_id,
    ct.chat_id,
    se.user_id
  from current_chats ct
  join public.student_enrollments se
    on se.group_id = ct.group_id
   and se.status = 'active'
   and se.ended_at is null
  where ct.team_id is not null
),
duplicate_teams as (
  select subject_offering_id, count(*)::bigint as duplicate_count
  from public.teams
  where subject_offering_id is not null
  group by subject_offering_id
  having count(*) > 1
),
duplicate_chats as (
  select team_id, count(*)::bigint as duplicate_count
  from public.chats
  where type = 'team_main'
    and team_id is not null
  group by team_id
  having count(*) > 1
),
duplicate_team_members as (
  select team_id, user_id, count(*)::bigint as duplicate_count
  from public.team_members
  group by team_id, user_id
  having count(*) > 1
),
duplicate_chat_members as (
  select chat_id, user_id, count(*)::bigint as duplicate_count
  from public.chat_members
  group by chat_id, user_id
  having count(*) > 1
)
select
  (select count(*)::bigint from current_offerings) as current_semester_subject_offerings_total,
  (select count(*)::bigint from current_teams where team_id is not null) as current_semester_teams_total,
  (select count(*)::bigint from current_teams where team_id is not null and subject_offering_id is not null) as current_semester_teams_with_subject_offering_id,
  (select count(*)::bigint from current_chats where chat_id is not null) as current_semester_team_main_chats_total,
  (select count(*)::bigint from expected_members em join public.team_members tm on tm.team_id = em.team_id and tm.user_id = em.user_id) as current_semester_team_members_total,
  (select count(*)::bigint from expected_members em join public.chat_members cm on cm.chat_id = em.chat_id and cm.user_id = em.user_id) as current_semester_chat_members_total,
  (select count(*)::bigint from duplicate_teams) as duplicate_teams_for_subject_offering_id_total,
  (select count(*)::bigint from duplicate_chats) as duplicate_team_main_chats_total,
  (select count(*)::bigint from duplicate_team_members) as duplicate_team_members_total,
  (select count(*)::bigint from duplicate_chat_members) as duplicate_chat_members_total,
  (select count(*)::bigint from public.teams where subject_offering_id is null) as legacy_teams_without_subject_offering_id_total,
  (select count(*)::bigint from public.subject_offerings) as subject_offerings_total;

-- 2. Current-semester teams by group.
select
  ct.group_name,
  count(ct.team_id)::bigint as current_semester_teams_total,
  count(ct.team_id) filter (where ct.team_group_name = ct.group_name)::bigint as teams_with_compat_group_name
from (
  select
    g.name as group_name,
    t.id as team_id,
    t.group_name as team_group_name
  from public.subject_offerings so
  join public.groups g on g.id = so.group_id
  left join public.teams t on t.subject_offering_id = so.id
  where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
    and so.semester_number = 4
) ct
group by ct.group_name
order by ct.group_name;

-- 3. Current-semester teams/chats/member details.
select
  g.name as group_name,
  so.id as subject_offering_id,
  so.display_name,
  t.id as team_id,
  t.name as team_name,
  t.group_name as team_group_name,
  ch.id as team_main_chat_id,
  (
    select count(*)::bigint
    from public.student_enrollments se
    where se.group_id = so.group_id
      and se.status = 'active'
      and se.ended_at is null
  ) as expected_active_students,
  (
    select count(*)::bigint
    from public.team_members tm
    join public.student_enrollments se
      on se.user_id = tm.user_id
     and se.group_id = so.group_id
     and se.status = 'active'
     and se.ended_at is null
    where tm.team_id = t.id
  ) as actual_team_members,
  (
    select count(*)::bigint
    from public.chat_members cm
    join public.student_enrollments se
      on se.user_id = cm.user_id
     and se.group_id = so.group_id
     and se.status = 'active'
     and se.ended_at is null
    where cm.chat_id = ch.id
  ) as actual_chat_members
from public.subject_offerings so
join public.groups g on g.id = so.group_id
left join public.teams t on t.subject_offering_id = so.id
left join public.chats ch
  on ch.team_id = t.id
 and ch.type = 'team_main'
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
  and so.semester_number = 4
order by g.name, so.display_name;

-- 4. Missing links for current-semester offerings.
select
  g.name as group_name,
  so.id as subject_offering_id,
  so.display_name,
  array_remove(array[
    case when t.id is null then 'missing_team' end,
    case when t.subject_offering_id is null then 'team_missing_subject_offering_id' end,
    case when t.group_id is null then 'team_missing_group_id' end,
    case when t.subject_id is null then 'team_missing_subject_id' end,
    case when t.semester_number is distinct from 4 then 'team_wrong_semester_number' end,
    case when ch.id is null then 'missing_team_main_chat' end
  ], null) as issues
from public.subject_offerings so
join public.groups g on g.id = so.group_id
left join public.teams t on t.subject_offering_id = so.id
left join public.chats ch
  on ch.team_id = t.id
 and ch.type = 'team_main'
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
  and so.semester_number = 4
  and (
    t.id is null
    or t.subject_offering_id is null
    or t.group_id is null
    or t.subject_id is null
    or t.semester_number is distinct from 4
    or ch.id is null
  )
order by g.name, so.display_name;
