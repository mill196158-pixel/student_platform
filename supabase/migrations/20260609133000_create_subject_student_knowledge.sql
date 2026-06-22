-- Subject student knowledge layer.
--
-- Safe scope:
-- - creates new tables for student-authored subject knowledge and difficulty votes;
-- - creates read-only stats views;
-- - creates v2 RPCs that use subject_offering_id / subject_id keys only;
-- - adds non-destructive schedule-mapping columns to existing lessons;
-- - does not mutate subject_offerings, student imports, auth.users, legacy teams/chats.

create extension if not exists pgcrypto;

create table if not exists public.subject_student_profiles (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subject_catalog(id) on delete restrict,
  student_title text null,
  short_description text null,
  what_to_expect text null,
  how_to_pass text null,
  useful_materials_note text null,
  common_pitfalls text null,
  tags text[] not null default '{}',
  moderation_status text not null default 'draft',
  created_by uuid null references public.users(id) on delete set null,
  updated_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subject_student_profiles_subject_unique unique (subject_id),
  constraint subject_student_profiles_moderation_status_check
    check (moderation_status in ('draft', 'published', 'hidden'))
);

create index if not exists subject_student_profiles_subject_id_idx
on public.subject_student_profiles(subject_id);

create index if not exists subject_student_profiles_moderation_status_idx
on public.subject_student_profiles(moderation_status);

create table if not exists public.subject_offering_student_profiles (
  id uuid primary key default gen_random_uuid(),
  subject_offering_id uuid not null references public.subject_offerings(id) on delete restrict,
  local_description text null,
  teacher_specific_note text null,
  assessment_note text null,
  workload_note text null,
  semester_tips text null,
  moderation_status text not null default 'draft',
  created_by uuid null references public.users(id) on delete set null,
  updated_by uuid null references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subject_offering_student_profiles_offering_unique unique (subject_offering_id),
  constraint subject_offering_student_profiles_moderation_status_check
    check (moderation_status in ('draft', 'published', 'hidden'))
);

create index if not exists subject_offering_student_profiles_offering_id_idx
on public.subject_offering_student_profiles(subject_offering_id);

create index if not exists subject_offering_student_profiles_moderation_status_idx
on public.subject_offering_student_profiles(moderation_status);

create table if not exists public.subject_difficulty_votes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  subject_id uuid not null references public.subject_catalog(id) on delete restrict,
  subject_offering_id uuid not null references public.subject_offerings(id) on delete restrict,
  difficulty_rating int not null,
  workload_rating int null,
  usefulness_rating int null,
  exam_stress_rating int null,
  comment text null,
  is_anonymous boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint subject_difficulty_votes_user_offering_unique unique (user_id, subject_offering_id),
  constraint subject_difficulty_votes_difficulty_check check (difficulty_rating between 1 and 5),
  constraint subject_difficulty_votes_workload_check check (workload_rating is null or workload_rating between 1 and 5),
  constraint subject_difficulty_votes_usefulness_check check (usefulness_rating is null or usefulness_rating between 1 and 5),
  constraint subject_difficulty_votes_exam_stress_check check (exam_stress_rating is null or exam_stress_rating between 1 and 5)
);

create index if not exists subject_difficulty_votes_subject_id_idx
on public.subject_difficulty_votes(subject_id);

create index if not exists subject_difficulty_votes_subject_offering_id_idx
on public.subject_difficulty_votes(subject_offering_id);

create index if not exists subject_difficulty_votes_user_id_idx
on public.subject_difficulty_votes(user_id);

create or replace view public.subject_difficulty_stats_global
with (security_invoker = true)
as
select
  v.subject_id,
  count(*)::int as votes_count,
  round(avg(v.difficulty_rating)::numeric, 2) as avg_difficulty,
  round(avg(v.workload_rating)::numeric, 2) as avg_workload,
  round(avg(v.usefulness_rating)::numeric, 2) as avg_usefulness,
  round(avg(v.exam_stress_rating)::numeric, 2) as avg_exam_stress
from public.subject_difficulty_votes v
group by v.subject_id;

create or replace view public.subject_difficulty_stats_by_offering
with (security_invoker = true)
as
select
  v.subject_offering_id,
  so.subject_id,
  so.group_id,
  so.semester_number,
  count(*)::int as votes_count,
  round(avg(v.difficulty_rating)::numeric, 2) as avg_difficulty,
  round(avg(v.workload_rating)::numeric, 2) as avg_workload,
  round(avg(v.usefulness_rating)::numeric, 2) as avg_usefulness,
  round(avg(v.exam_stress_rating)::numeric, 2) as avg_exam_stress
from public.subject_difficulty_votes v
join public.subject_offerings so on so.id = v.subject_offering_id
group by v.subject_offering_id, so.subject_id, so.group_id, so.semester_number;

alter table public.lessons
  add column if not exists raw_subject_name text null,
  add column if not exists normalized_subject_name text null,
  add column if not exists alias_match_status text not null default 'pending';

alter table public.lessons
  drop constraint if exists lessons_alias_match_status_check;

alter table public.lessons
  add constraint lessons_alias_match_status_check
  check (alias_match_status in ('matched', 'pending', 'ambiguous', 'ignored'));

create index if not exists lessons_normalized_subject_name_idx
on public.lessons(normalized_subject_name)
where normalized_subject_name is not null;

create index if not exists lessons_alias_match_status_idx
on public.lessons(alias_match_status);

create index if not exists lessons_group_semester_subject_idx
on public.lessons(group_id, semester_number, subject_id, subject_offering_id);

create or replace function public.rpc_vote_subject_difficulty_v2(
  p_subject_offering_id uuid,
  p_difficulty_rating int,
  p_workload_rating int default null,
  p_usefulness_rating int default null,
  p_exam_stress_rating int default null,
  p_comment text default null,
  p_is_anonymous boolean default true
)
returns table (
  id uuid,
  user_id uuid,
  subject_id uuid,
  subject_offering_id uuid,
  difficulty_rating int,
  workload_rating int,
  usefulness_rating int,
  exam_stress_rating int,
  comment text,
  is_anonymous boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_offering public.subject_offerings%rowtype;
  v_current_semester int;
begin
  if v_user_id is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  if not exists (select 1 from public.users u where u.id = v_user_id) then
    raise exception 'user_profile_not_found' using errcode = '28000';
  end if;

  if p_difficulty_rating not between 1 and 5
    or (p_workload_rating is not null and p_workload_rating not between 1 and 5)
    or (p_usefulness_rating is not null and p_usefulness_rating not between 1 and 5)
    or (p_exam_stress_rating is not null and p_exam_stress_rating not between 1 and 5)
  then
    raise exception 'rating_out_of_range' using errcode = '22003';
  end if;

  select so.*
  into v_offering
  from public.subject_offerings so
  where so.id = p_subject_offering_id;

  if not found then
    raise exception 'subject_offering_not_found' using errcode = 'P0002';
  end if;

  select coalesce(
    (
      select gts.semester_number
      from public.group_term_semesters gts
      join public.academic_terms at on at.id = gts.academic_term_id
      where gts.group_id = v_offering.group_id
        and at.is_current
      order by at.term_sequence desc, gts.semester_number desc
      limit 1
    ),
    (
      select max(gts.semester_number)
      from public.group_term_semesters gts
      where gts.group_id = v_offering.group_id
    )
  )
  into v_current_semester;

  if v_current_semester is null then
    raise exception 'group_current_semester_not_found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1
    from public.student_enrollments se
    where se.user_id = v_user_id
      and se.group_id = v_offering.group_id
      and (
        (se.status = 'active' and se.ended_at is null)
        or se.status in ('transferred', 'completed', 'left', 'archived')
        or se.ended_at is not null
      )
  ) then
    raise exception 'student_not_enrolled_for_offering_group' using errcode = '42501';
  end if;

  if v_offering.semester_number > v_current_semester then
    raise exception 'subject_offering_is_future' using errcode = '42501';
  end if;

  return query
  insert into public.subject_difficulty_votes (
    user_id,
    subject_id,
    subject_offering_id,
    difficulty_rating,
    workload_rating,
    usefulness_rating,
    exam_stress_rating,
    comment,
    is_anonymous,
    updated_at
  )
  values (
    v_user_id,
    v_offering.subject_id,
    v_offering.id,
    p_difficulty_rating,
    p_workload_rating,
    p_usefulness_rating,
    p_exam_stress_rating,
    nullif(trim(p_comment), ''),
    coalesce(p_is_anonymous, true),
    now()
  )
  on conflict (user_id, subject_offering_id)
  do update set
    subject_id = excluded.subject_id,
    difficulty_rating = excluded.difficulty_rating,
    workload_rating = excluded.workload_rating,
    usefulness_rating = excluded.usefulness_rating,
    exam_stress_rating = excluded.exam_stress_rating,
    comment = excluded.comment,
    is_anonymous = excluded.is_anonymous,
    updated_at = now()
  returning
    subject_difficulty_votes.id,
    subject_difficulty_votes.user_id,
    subject_difficulty_votes.subject_id,
    subject_difficulty_votes.subject_offering_id,
    subject_difficulty_votes.difficulty_rating,
    subject_difficulty_votes.workload_rating,
    subject_difficulty_votes.usefulness_rating,
    subject_difficulty_votes.exam_stress_rating,
    subject_difficulty_votes.comment,
    subject_difficulty_votes.is_anonymous,
    subject_difficulty_votes.created_at,
    subject_difficulty_votes.updated_at;
end;
$$;

create or replace function public.rpc_get_my_subjects_v2()
returns table (
  subject_offering_id uuid,
  subject_id uuid,
  group_id uuid,
  semester_number int,
  visibility_status text,
  subject_title text,
  control_form text,
  department text,
  short_description text,
  local_description text,
  avg_difficulty_global numeric,
  avg_difficulty_local numeric,
  votes_count_global int,
  votes_count_local int,
  user_vote jsonb,
  has_team boolean,
  team_id uuid,
  chat_id uuid,
  can_vote boolean,
  can_open_chat boolean,
  cannot_vote_reason text,
  credits numeric,
  hours_total int,
  subject_index text,
  block_name text,
  how_to_pass text,
  common_pitfalls text,
  semester_tips text,
  assessment_note text
)
language sql
security definer
set search_path = public, pg_temp
as $$
with current_user_profile as (
  select auth.uid() as user_id
),
active_enrollment as (
  select se.user_id, se.group_id
  from public.student_enrollments se
  join current_user_profile cup on cup.user_id = se.user_id
  where se.status = 'active'
    and se.ended_at is null
  order by se.started_at desc, se.created_at desc
  limit 1
),
current_semester as (
  select ae.group_id,
         coalesce(
           (
             select gts.semester_number
             from public.group_term_semesters gts
             join public.academic_terms at on at.id = gts.academic_term_id
             where gts.group_id = ae.group_id
               and at.is_current
             order by at.term_sequence desc, gts.semester_number desc
             limit 1
           ),
           (
             select max(gts.semester_number)
             from public.group_term_semesters gts
             where gts.group_id = ae.group_id
           ),
           1
         ) as semester_number
  from active_enrollment ae
),
team_chat as (
  select distinct on (t.subject_offering_id)
    t.subject_offering_id,
    t.id as team_id,
    ch.id as chat_id
  from public.teams t
  left join public.chats ch
    on ch.team_id = t.id
   and ch.type = 'team_main'
  join current_user_profile cup on true
  where t.subject_offering_id is not null
    and exists (
      select 1
      from public.team_members tm
      where tm.team_id = t.id
        and tm.user_id = cup.user_id
    )
  order by t.subject_offering_id, ch.created_at asc nulls last
)
select
  so.id as subject_offering_id,
  so.subject_id,
  so.group_id,
  so.semester_number,
  case
    when so.semester_number < cs.semester_number then 'archived'
    when so.semester_number = cs.semester_number then 'current'
    else 'future'
  end as visibility_status,
  coalesce(
    nullif(trim(cs_sub.display_name), ''),
    nullif(trim(cs_sub.raw_subject_name), ''),
    nullif(trim(so.display_name), ''),
    nullif(trim(sc.canonical_name), ''),
    'Без названия'
  ) as subject_title,
  coalesce(cs_sub.control_form, '') as control_form,
  coalesce(cs_sub.department, '') as department,
  ssp.short_description,
  sosp.local_description,
  sglobal.avg_difficulty as avg_difficulty_global,
  slocal.avg_difficulty as avg_difficulty_local,
  coalesce(sglobal.votes_count, 0) as votes_count_global,
  coalesce(slocal.votes_count, 0) as votes_count_local,
  case
    when uv.id is null then null
    else jsonb_build_object(
      'id', uv.id,
      'difficulty_rating', uv.difficulty_rating,
      'workload_rating', uv.workload_rating,
      'usefulness_rating', uv.usefulness_rating,
      'exam_stress_rating', uv.exam_stress_rating,
      'comment', uv.comment,
      'is_anonymous', uv.is_anonymous,
      'updated_at', uv.updated_at
    )
  end as user_vote,
  tc.team_id is not null as has_team,
  tc.team_id,
  tc.chat_id,
  so.semester_number <= cs.semester_number as can_vote,
  tc.chat_id is not null and so.semester_number <= cs.semester_number as can_open_chat,
  case
    when so.semester_number > cs.semester_number then 'Предмет ещё не начался'
    else null
  end as cannot_vote_reason,
  cs_sub.credits,
  cs_sub.hours_total,
  coalesce(cs_sub.subject_index, '') as subject_index,
  coalesce(cs_sub.block_name, '') as block_name,
  ssp.how_to_pass,
  ssp.common_pitfalls,
  sosp.semester_tips,
  sosp.assessment_note
from active_enrollment ae
join current_semester cs on cs.group_id = ae.group_id
join public.subject_offerings so on so.group_id = ae.group_id
join public.subject_catalog sc on sc.id = so.subject_id
left join public.curriculum_subjects cs_sub on cs_sub.id = so.curriculum_subject_id
left join public.subject_student_profiles ssp
  on ssp.subject_id = so.subject_id
 and ssp.moderation_status = 'published'
left join public.subject_offering_student_profiles sosp
  on sosp.subject_offering_id = so.id
 and sosp.moderation_status = 'published'
left join public.subject_difficulty_stats_global sglobal on sglobal.subject_id = so.subject_id
left join public.subject_difficulty_stats_by_offering slocal on slocal.subject_offering_id = so.id
left join public.subject_difficulty_votes uv
  on uv.subject_offering_id = so.id
 and uv.user_id = ae.user_id
left join team_chat tc on tc.subject_offering_id = so.id
where so.status <> 'cancelled'
order by so.semester_number, subject_title;
$$;

comment on table public.subject_student_profiles is
  'General student-facing subject knowledge keyed by subject_id. Does not use subject names as keys.';

comment on table public.subject_offering_student_profiles is
  'Local student-facing notes for one group/semester offering keyed by subject_offering_id.';

comment on table public.subject_difficulty_votes is
  'One vote per user and subject_offering_id. Upserts are handled by rpc_vote_subject_difficulty_v2.';

comment on column public.lessons.raw_subject_name is
  'Optional raw schedule subject name. Existing lessons.subject remains the legacy raw source when this is null.';

comment on column public.lessons.normalized_subject_name is
  'Normalized schedule subject name for matching against subject_aliases.normalized_alias.';

comment on column public.lessons.alias_match_status is
  'Schedule alias matching state: matched, pending, ambiguous, ignored. Never creates subject_catalog rows automatically.';
