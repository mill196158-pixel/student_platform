-- Reviewed subgroup allocations are supplemental to the published group timetable.
-- A roster key identifies one allocation (e.g. a term's laboratory roster).
-- Keys and codes come from its owner; student names and group-name suffixes are
-- deliberately never used to derive an allocation.
create table private.schedule_subgroup_roster (
  enrollment_id uuid not null references public.student_enrollments(id) on delete cascade,
  roster_key text not null check (btrim(roster_key) <> ''),
  subgroup_code text not null check (btrim(subgroup_code) <> ''),
  source_ref text not null check (btrim(source_ref) <> ''),
  primary key (enrollment_id, roster_key)
);

-- The RASP group sync replaces lesson UUIDs. Use the explicit occurrence
-- (as published by RASP) to retain an annotation across an unchanged reimport.
create table private.schedule_subgroup_occurrences (
  group_id uuid not null references public.groups(id) on delete cascade,
  lesson_date date not null,
  starts_at time not null,
  subject_key text not null,
  room_key text not null,
  roster_key text not null check (btrim(roster_key) <> ''),
  subgroup_code text check (btrim(subgroup_code) <> ''),
  source_ref text not null check (btrim(source_ref) <> ''),
  primary key (group_id, lesson_date, starts_at, subject_key, room_key, roster_key)
);
revoke all on private.schedule_subgroup_roster, private.schedule_subgroup_occurrences
  from public, anon, authenticated;

-- Only a trusted operator can write these inputs. Replacing a record is atomic.
create function private.set_schedule_enrollment_subgroup(
  p_enrollment_id uuid, p_roster_key text, p_subgroup_code text, p_source_ref text
) returns void language sql set search_path = '' as $$
  insert into private.schedule_subgroup_roster(enrollment_id,roster_key,subgroup_code,source_ref)
  values(p_enrollment_id,btrim(p_roster_key),btrim(p_subgroup_code),btrim(p_source_ref))
  on conflict (enrollment_id,roster_key) do update
    set subgroup_code=excluded.subgroup_code,source_ref=excluded.source_ref;
$$;
revoke all on function private.set_schedule_enrollment_subgroup(uuid,text,text,text)
  from public, anon, authenticated;

-- Staff register the exact occurrence they reviewed. An explicit NULL code
-- marks a room as shared (for parallel sessions in an annotated slot).
-- Room disambiguates two simultaneous sessions. A new room in an annotated
-- slot stays out of the personal timetable until its assignment is confirmed.
create function private.tag_schedule_subgroup_lesson(
  p_lesson_id uuid, p_roster_key text, p_subgroup_code text, p_source_ref text
) returns void language plpgsql set search_path = '' as $$
declare
  lesson public.lessons%rowtype;
begin
  select * into strict lesson from public.lessons where id = p_lesson_id;
  if exists (select 1 from public.lessons b
    where b.group_id=lesson.group_id and b.date=lesson.date and b.time_start=lesson.time_start
      and btrim(coalesce(nullif(b.raw_subject_name,''),b.subject)) = btrim(coalesce(nullif(lesson.raw_subject_name,''),lesson.subject))
      and btrim(coalesce(b.room,''))=btrim(coalesce(lesson.room,'')) and b.id<>lesson.id) then
    raise exception 'Ambiguous timetable occurrence' using errcode='22023';
  end if;
  insert into private.schedule_subgroup_occurrences
    (group_id, lesson_date, starts_at, subject_key, room_key, roster_key, subgroup_code, source_ref)
  values (lesson.group_id, lesson.date, lesson.time_start,
    btrim(coalesce(nullif(lesson.raw_subject_name,''), lesson.subject)),
    btrim(coalesce(lesson.room,'')), btrim(p_roster_key), btrim(p_subgroup_code), btrim(p_source_ref))
  on conflict (group_id, lesson_date, starts_at, subject_key, room_key, roster_key)
  do update set subgroup_code=excluded.subgroup_code, source_ref=excluded.source_ref;
end $$;
revoke all on function private.tag_schedule_subgroup_lesson(uuid,text,text,text)
  from public, anon, authenticated;

create function private.my_personal_schedule(p_from date, p_until date)
returns setof public.lessons language sql stable set search_path = '' as $$
  with active as materialized (
    select e.id, e.group_id from public.student_enrollments e
    where e.user_id = (select auth.uid()) and e.status = 'active' and e.ended_at is null
  ), my_groups as (
    select group_id from active
    union all
    select g.id from public.groups g
    join public.users u on u.group_name = g.name
    where u.id = (select auth.uid()) and not exists (select 1 from public.student_enrollments e where e.user_id=u.id)
  )
  select l.* from public.lessons l
  where l.group_id in (select group_id from my_groups)
    and l.date >= p_from and l.date < p_until
    and coalesce((
      select bool_or(
        o.room_key = btrim(coalesce(l.room,'')) and
        not exists (select 1 from public.lessons b where b.group_id=l.group_id and b.date=l.date
                    and b.time_start=l.time_start and b.id<>l.id and btrim(coalesce(b.room,''))=o.room_key
                    and btrim(coalesce(nullif(b.raw_subject_name,''),b.subject))=o.subject_key) and
        (o.subgroup_code is null or exists (select 1 from active a join private.schedule_subgroup_roster r on r.enrollment_id = a.id
                where a.group_id = l.group_id and r.roster_key = o.roster_key and r.subgroup_code = o.subgroup_code))
      )
      from private.schedule_subgroup_occurrences o
      where o.group_id = l.group_id and o.lesson_date = l.date and o.starts_at = l.time_start
        and o.subject_key = btrim(coalesce(nullif(l.raw_subject_name,''), l.subject))
    ), true);
$$;
revoke all on function private.my_personal_schedule(date,date) from public, anon, authenticated;

-- Preserve the legacy RPC shape used by existing mobile releases.
create or replace function public.get_my_lessons(
  p_from date default current_date, p_days integer default 14
) returns table(id uuid, week integer, day text, date date, pair_num integer,
  time_start time, time_end time, subject text, room text, teacher text)
language sql stable security definer set search_path = '' as $$
  select l.id,l.week,l.day,l.date,l.pair_num,l.time_start,l.time_end,l.subject,l.room,l.teacher
  from private.my_personal_schedule(p_from,p_from+p_days) l
  order by l.date,l.pair_num,l.time_start,l.id;
$$;

create function public.get_my_diary_schedule_lessons(p_group_id uuid,p_from date,p_to date)
returns table(id uuid,date date,subject text,group_id uuid,subject_id uuid,
  subject_offering_id uuid,semester_number integer,pair_num integer,time_start time)
language sql stable security definer set search_path = '' as $$
  select l.id,l.date,l.subject,l.group_id,l.subject_id,l.subject_offering_id,
         l.semester_number,l.pair_num,l.time_start
  from private.my_personal_schedule(p_from,p_to+1) l
  where l.group_id=p_group_id and l.subject_offering_id is not null
  order by l.date desc,l.pair_num,l.time_start,l.id limit 120;
$$;
revoke all on function public.get_my_diary_schedule_lessons(uuid,date,date) from public, anon;
grant execute on function public.get_my_diary_schedule_lessons(uuid,date,date) to authenticated;
