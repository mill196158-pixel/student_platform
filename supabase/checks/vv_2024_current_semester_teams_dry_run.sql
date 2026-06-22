-- Read-only dry-run for creating VV 2024 current-semester teams/chats.
-- This file intentionally contains SELECT statements only.

-- 1. Summary for semester 4 subject_offerings, teams, chats, and memberships.
with current_offerings as (
  select
    so.id as subject_offering_id,
    so.group_id,
    g.name as group_name,
    so.subject_id,
    sc.canonical_name as subject_name,
    so.display_name,
    so.academic_year_id,
    so.academic_term_id,
    so.semester_number
  from public.subject_offerings so
  join public.groups g on g.id = so.group_id
  join public.subject_catalog sc on sc.id = so.subject_id
  where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
    and so.semester_number = 4
),
resolved as (
  select
    co.*,
    t_by_offering.id as team_by_offering_id,
    legacy.id as legacy_team_by_name_id,
    current_team.id as current_team_id,
    current_chat.id as current_chat_id,
    (
      select count(*)::bigint
      from public.student_enrollments se
      where se.group_id = co.group_id
        and se.status = 'active'
        and se.ended_at is null
    ) as active_students_total,
    (
      select count(*)::bigint
      from public.users u
      where u.group_name = co.group_name
    ) as users_with_group_name_total,
    (
      select count(*)::bigint
      from public.team_members tm
      join public.student_enrollments se
        on se.user_id = tm.user_id
       and se.group_id = co.group_id
       and se.status = 'active'
       and se.ended_at is null
      where tm.team_id = current_team.id
    ) as existing_current_team_members_total,
    (
      select count(*)::bigint
      from public.chat_members cm
      join public.student_enrollments se
        on se.user_id = cm.user_id
       and se.group_id = co.group_id
       and se.status = 'active'
       and se.ended_at is null
      where cm.chat_id = current_chat.id
    ) as existing_current_chat_members_total
  from current_offerings co
  left join public.teams t_by_offering on t_by_offering.subject_offering_id = co.subject_offering_id
  left join public.teams legacy
    on legacy.subject_offering_id is null
   and legacy.group_name = co.group_name
   and public.f_norm_subject(legacy.name) = public.f_norm_subject(co.display_name)
  left join public.teams current_team on current_team.subject_offering_id = co.subject_offering_id
  left join public.chats current_chat
    on current_chat.team_id = current_team.id
   and current_chat.type = 'team_main'
),
team_candidates as (
  select *
  from resolved
  where team_by_offering_id is null
    and legacy_team_by_name_id is null
    and group_id is not null
    and subject_id is not null
    and subject_offering_id is not null
),
blocked as (
  select
    *,
    array_remove(array[
      case when group_id is null then 'missing_group_id' end,
      case when subject_id is null then 'missing_subject_id' end,
      case when subject_offering_id is null then 'missing_subject_offering_id' end,
      case when team_by_offering_id is not null then 'team_already_exists_for_subject_offering_id' end,
      case when legacy_team_by_name_id is not null then 'legacy_team_name_conflict' end,
      case when active_students_total = 0 then 'missing_active_enrollments' end
    ], null) as reasons
  from resolved
  where group_id is null
     or subject_id is null
     or subject_offering_id is null
     or legacy_team_by_name_id is not null
     or active_students_total = 0
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
  (select count(*)::bigint from current_offerings where group_name = '1-См(ВВ)-2') as current_semester_offerings_group_1_total,
  (select count(*)::bigint from current_offerings where group_name = '2-См(ВВ)-2') as current_semester_offerings_group_2_total,
  (select count(*)::bigint from team_candidates) as teams_to_create,
  (select count(*)::bigint from team_candidates) as chats_to_create_by_teams_trigger,
  (select coalesce(sum(active_students_total), 0)::bigint from team_candidates) as team_members_to_create_from_active_enrollments,
  (select coalesce(sum(active_students_total), 0)::bigint from team_candidates) as chat_members_expected_via_team_member_trigger,
  (select count(*)::bigint from resolved where team_by_offering_id is not null) as existing_teams_by_subject_offering_id,
  (select count(*)::bigint from resolved where legacy_team_by_name_id is not null) as legacy_name_conflicts_total,
  (select count(*)::bigint from blocked) as blocked_rows_total,
  (select count(*)::bigint from duplicate_teams) as duplicate_teams_for_subject_offering_id_total,
  (select count(*)::bigint from duplicate_chats) as duplicate_team_main_chats_total,
  (select count(*)::bigint from duplicate_team_members) as duplicate_team_members_total,
  (select count(*)::bigint from duplicate_chat_members) as duplicate_chat_members_total,
  (select count(*)::bigint from resolved where active_students_total = 0) as missing_active_enrollments_total,
  (select count(*)::bigint from resolved where group_id is null) as missing_group_id_total,
  (select count(*)::bigint from resolved where subject_id is null) as missing_subject_id_total,
  (select count(*)::bigint from resolved where subject_offering_id is null) as missing_subject_offering_id_total;

-- 2. Current semester subject_offerings by group and subject.
select
  g.name as group_name,
  so.id as subject_offering_id,
  so.semester_number,
  so.display_name,
  sc.canonical_name as subject_name,
  so.subject_id
from public.subject_offerings so
join public.groups g on g.id = so.group_id
join public.subject_catalog sc on sc.id = so.subject_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
  and so.semester_number = 4
order by g.name, so.display_name;

-- 3. Existing teams/chats and legacy-name conflicts for current offerings.
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
)
select
  co.group_name,
  co.subject_offering_id,
  co.display_name,
  t_by_offering.id as team_by_subject_offering_id,
  t_by_key.id as team_by_group_subject_semester,
  legacy.id as legacy_team_by_name,
  legacy.name as legacy_team_name,
  ch.id as existing_team_main_chat_id
from current_offerings co
left join public.teams t_by_offering on t_by_offering.subject_offering_id = co.subject_offering_id
left join public.teams t_by_key
  on t_by_key.group_id = co.group_id
 and t_by_key.subject_id = co.subject_id
 and t_by_key.semester_number = co.semester_number
left join public.teams legacy
  on legacy.subject_offering_id is null
 and legacy.group_name = co.group_name
 and public.f_norm_subject(legacy.name) = public.f_norm_subject(co.display_name)
left join public.chats ch
  on ch.team_id = t_by_offering.id
 and ch.type = 'team_main'
order by co.group_name, co.display_name;

-- 4. Active students expected for each new/current-semester team.
select
  g.name as group_name,
  so.id as subject_offering_id,
  so.display_name,
  count(se.user_id)::bigint as active_students_total,
  count(u.id)::bigint as users_with_group_name_total
from public.subject_offerings so
join public.groups g on g.id = so.group_id
left join public.student_enrollments se
  on se.group_id = so.group_id
 and se.status = 'active'
 and se.ended_at is null
left join public.users u on u.id = se.user_id and u.group_name = g.name
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
  and so.semester_number = 4
group by g.name, so.id, so.display_name
order by g.name, so.display_name;

-- 5. Blocked rows requiring manual decision.
with current_offerings as (
  select
    so.id as subject_offering_id,
    so.group_id,
    g.name as group_name,
    so.subject_id,
    so.display_name,
    so.semester_number,
    (
      select count(*)::bigint
      from public.student_enrollments se
      where se.group_id = so.group_id
        and se.status = 'active'
        and se.ended_at is null
    ) as active_students_total
  from public.subject_offerings so
  join public.groups g on g.id = so.group_id
  where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
    and so.semester_number = 4
),
resolved as (
  select
    co.*,
    legacy.id as legacy_team_by_name_id
  from current_offerings co
  left join public.teams legacy
    on legacy.subject_offering_id is null
   and legacy.group_name = co.group_name
   and public.f_norm_subject(legacy.name) = public.f_norm_subject(co.display_name)
)
select
  group_name,
  subject_offering_id,
  display_name,
  array_remove(array[
    case when group_id is null then 'missing_group_id' end,
    case when subject_id is null then 'missing_subject_id' end,
    case when subject_offering_id is null then 'missing_subject_offering_id' end,
    case when legacy_team_by_name_id is not null then 'legacy_team_name_conflict' end,
    case when active_students_total = 0 then 'missing_active_enrollments' end
  ], null) as reasons
from resolved
where group_id is null
   or subject_id is null
   or subject_offering_id is null
   or legacy_team_by_name_id is not null
   or active_students_total = 0
order by group_name, display_name;
