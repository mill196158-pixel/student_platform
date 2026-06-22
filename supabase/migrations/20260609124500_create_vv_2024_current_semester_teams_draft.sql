-- DRAFT ONLY. Do not apply until the dry-run is reviewed and explicitly approved.
--
-- Scope:
-- - create teams only for VV 2024 current semester (semester 4) subject_offerings;
-- - rely on existing teams AFTER INSERT trigger to create team_main chats;
-- - add team_members only from active student_enrollments;
-- - rely on existing team_members AFTER INSERT trigger to create chat_members;
-- - do not touch legacy teams/chats/memberships, auth.users, public.users,
--   student_enrollments, RLS policies, or backfill flows.

begin;

create temporary table tmp_vv_2024_current_team_candidates on commit drop as
select
  so.id as subject_offering_id,
  so.group_id,
  g.name as group_name,
  so.subject_id,
  so.academic_year_id,
  so.academic_term_id,
  so.semester_number,
  so.display_name as team_name
from public.subject_offerings so
join public.groups g on g.id = so.group_id
where g.name in ('1-См(ВВ)-2', '2-См(ВВ)-2')
  and so.semester_number = 4
  and so.id is not null
  and so.group_id is not null
  and so.subject_id is not null
  and not exists (
    select 1
    from public.teams existing
    where existing.subject_offering_id = so.id
  )
  and not exists (
    select 1
    from public.teams legacy
    where legacy.subject_offering_id is null
      and legacy.group_name = g.name
      and public.f_norm_subject(legacy.name) = public.f_norm_subject(so.display_name)
  )
  and exists (
    select 1
    from public.student_enrollments se
    where se.group_id = so.group_id
      and se.status = 'active'
      and se.ended_at is null
  );

insert into public.teams (
  name,
  description,
  teacher,
  icon,
  group_name,
  group_id,
  subject_id,
  subject_offering_id,
  academic_year_id,
  academic_term_id,
  semester_number
)
select
  team_name,
  '',
  '',
  '',
  null,
  group_id,
  subject_id,
  subject_offering_id,
  academic_year_id,
  academic_term_id,
  semester_number
from tmp_vv_2024_current_team_candidates
on conflict do nothing;

insert into public.team_members (
  team_id,
  user_id,
  role
)
select
  t.id,
  se.user_id,
  'member'
from tmp_vv_2024_current_team_candidates c
join public.teams t on t.subject_offering_id = c.subject_offering_id
join public.student_enrollments se
  on se.group_id = c.group_id
 and se.status = 'active'
 and se.ended_at is null
where not exists (
  select 1
  from public.team_members existing
  where existing.team_id = t.id
    and existing.user_id = se.user_id
)
on conflict do nothing;

update public.teams t
set
  group_name = c.group_name,
  updated_at = now()
from tmp_vv_2024_current_team_candidates c
where t.subject_offering_id = c.subject_offering_id
  and nullif(trim(coalesce(t.group_name, '')), '') is null
  and not exists (
    select 1
    from public.teams other
    where other.id <> t.id
      and other.group_name = c.group_name
      and public.f_norm_subject(other.name) = public.f_norm_subject(t.name)
  );

select
  (select count(*) from tmp_vv_2024_current_team_candidates) as team_candidates_seen,
  (
    select count(*)
    from public.teams t
    join tmp_vv_2024_current_team_candidates c on c.subject_offering_id = t.subject_offering_id
  ) as current_semester_teams_present,
  (
    select count(*)
    from public.chats ch
    join public.teams t on t.id = ch.team_id
    join tmp_vv_2024_current_team_candidates c on c.subject_offering_id = t.subject_offering_id
    where ch.type = 'team_main'
  ) as current_semester_team_main_chats_present,
  (
    select count(*)
    from public.team_members tm
    join public.teams t on t.id = tm.team_id
    join tmp_vv_2024_current_team_candidates c on c.subject_offering_id = t.subject_offering_id
  ) as current_semester_team_members_present,
  (
    select count(*)
    from public.chat_members cm
    join public.chats ch on ch.id = cm.chat_id
    join public.teams t on t.id = ch.team_id
    join tmp_vv_2024_current_team_candidates c on c.subject_offering_id = t.subject_offering_id
    where ch.type = 'team_main'
  ) as current_semester_chat_members_present;

commit;
