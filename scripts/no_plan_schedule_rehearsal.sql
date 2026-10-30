-- Synthetic primary-database rehearsal. No persistent writes: always ROLLBACK.
begin;
set local statement_timeout = '15s';
do $$
declare
  g uuid := gen_random_uuid();
  s uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid();
  term_id uuid; year_id uuid;
  marker text := 'E2E-no-plan-' || g::text;
  r record;
begin
  select id,academic_year_id into term_id,year_id
    from public.academic_terms order by is_current desc,starts_on desc limit 1;
  assert term_id is not null, 'term required';
  insert into public.groups(id,name) values(g,marker);
  assert not exists(select 1 from public.group_academic_profiles where group_id=g), 'fixture has no plan';
  insert into public.subject_catalog(id,canonical_name,normalized_name)
    values(s,marker,lower(marker)),(s2,marker||'-second',lower(marker)||'-second');
  select * into r from public.resolve_subject_offering_for_schedule(g,marker,null,1);
  assert r.match_status='not_found', 'unprovisioned schedule must not invent offering';
  insert into public.subject_offerings(subject_id,group_id,academic_year_id,academic_term_id,semester_number,display_name)
    values(s,g,year_id,term_id,1,marker);
  select * into r from public.resolve_subject_offering_for_schedule(g,upper(marker),null,1);
  assert r.match_status='matched' and r.subject_id=s, 'case normalization without curriculum';
  insert into public.subject_aliases(subject_id,alias,normalized_alias)
    values(s,marker||'-alias',public.f_norm_schedule_subject(marker||'-alias'));
  select * into r from public.resolve_subject_offering_for_schedule(g,marker||'-alias',null,1);
  assert r.match_status='matched' and r.candidates_count=1, 'alias should not duplicate candidate';
  insert into public.subject_offerings(subject_id,group_id,academic_year_id,academic_term_id,semester_number,display_name)
    values(s2,g,year_id,term_id,1,marker);
  select * into r from public.resolve_subject_offering_for_schedule(g,marker,null,1);
  assert r.match_status='ambiguous' and r.subject_id is null, 'ambiguous name must remain unresolved';
end $$;
rollback;
select 'PASS: no-plan matching, alias dedupe, ambiguity; rolled back' as result;
