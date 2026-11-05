begin;

-- Reconcile the current guest list against confirmed timetable links.
-- The imported curriculum remains the fallback and supplies placements.
create function private.guest_group_subjects(
  p_group uuid, p_query text, p_offset integer
) returns jsonb
language sql stable security definer set search_path = ''
as $$
  with term_candidates as (
    select t.id, t.starts_on, t.ends_on, count(*) over () as matches
    from public.academic_terms t
    where (statement_timestamp() at time zone 'Europe/Moscow')::date
          between t.starts_on and t.ends_on
      and exists (
        select 1 from private.guest_public_groups pg where pg.group_id = p_group
      )
  ), current_term as (
    select id, starts_on, ends_on from term_candidates where matches = 1
  ), scheduled_subjects as (
    select distinct coalesce(l.subject_id, linked.subject_id) as subject_id
    from current_term t
    join public.lessons l on l.group_id = p_group and l.date between t.starts_on and t.ends_on
    left join public.subject_offerings linked on linked.id = l.subject_offering_id
    where l.alias_match_status = 'matched'
      and (l.academic_term_id is null or l.academic_term_id = t.id)
      and coalesce(l.subject_id, linked.subject_id) is not null
      and (l.subject_offering_id is null or (
        linked.group_id = p_group and linked.academic_term_id = t.id
        and linked.status = 'active'
        and (l.subject_id is null or l.subject_id = linked.subject_id)
      ))
  ), eligible_subjects as (
    -- A confirmed draft still proves which course is taught. Publication
    -- controls the final projection, never whether to fall back to the plan.
    select subject_id from scheduled_subjects
    union
    select so.subject_id
    from current_term t
    join public.subject_offerings so
      on so.group_id = p_group and so.academic_term_id = t.id and so.status = 'active'
    left join public.curriculum_subjects cs on cs.id = so.curriculum_subject_id
    cross join (values (
      'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ', 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'
    )) as c(uppercase, lowercase)
    where not exists (select 1 from scheduled_subjects)
      or btrim(cs.subject_index) ~* '^[БBбb]2([.[:space:]]|$)'
      or translate(btrim(cs.block_name), c.uppercase, c.lowercase) ~ '^практик[аи]$'
      or translate(btrim(coalesce(nullif(btrim(cs.display_name), ''), cs.raw_subject_name)),
                   c.uppercase, c.lowercase) ~
        '^(практика|((учебная|производственная|преддипломная|проектная|ознакомительная|технологическая|педагогическая|профессиональная|исследовательская)[[:space:]]+)+практика)($|[[:space:][:punct:]])'
  )
  select coalesce(jsonb_agg(to_jsonb(subject) order by subject.title, subject.id), '[]'::jsonb)
  from (
    select sc.id, sc.canonical_name as title, sc.control_form, sc.description,
           sc.department, sc.requirements, sc.learning_outcomes
    from eligible_subjects eligible
    join public.subject_catalog sc on sc.id = eligible.subject_id
    where sc.status = 'published'
      and strpos(lower(sc.canonical_name), lower(btrim(coalesce(p_query, '')))) > 0
    order by sc.canonical_name, sc.id
    limit 50 offset greatest(coalesce(p_offset, 0), 0)
  ) subject;
$$;

-- Resolve the private helper at definition time. Guest roles need no
-- USAGE on the private schema and no table privileges.
create function public.get_guest_group_subjects(
  p_group uuid, p_query text default '', p_offset integer default 0
) returns jsonb
language sql stable security invoker set search_path = ''
return private.guest_group_subjects(p_group, p_query, p_offset);

revoke all on function private.guest_group_subjects(uuid, text, integer)
  from public, anon, authenticated;
revoke all on function public.get_guest_group_subjects(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function private.guest_group_subjects(uuid, text, integer)
  to anon, authenticated;
grant execute on function public.get_guest_group_subjects(uuid, text, integer)
  to anon, authenticated;

commit;
