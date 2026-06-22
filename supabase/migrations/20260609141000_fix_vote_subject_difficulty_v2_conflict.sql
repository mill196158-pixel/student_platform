-- Fix rpc_vote_subject_difficulty_v2 ON CONFLICT ambiguity.
--
-- The function returns a table with an output column named user_id. In PL/pgSQL,
-- ON CONFLICT (user_id, subject_offering_id) can be resolved ambiguously against
-- that output variable. Use the unique constraint name instead.

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
  on conflict on constraint subject_difficulty_votes_user_offering_unique
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
