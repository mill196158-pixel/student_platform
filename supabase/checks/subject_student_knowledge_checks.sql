-- Subject student knowledge dry-run / post-checks.
--
-- Run after applying 20260609133000_create_subject_student_knowledge.sql
-- and before wiring production usage broadly. All result sets are read-only.

-- 1. Duplicate votes must be impossible with the unique constraint.
select
  'duplicate_votes' as check_name,
  user_id,
  subject_offering_id,
  count(*) as duplicates_count
from public.subject_difficulty_votes
group by user_id, subject_offering_id
having count(*) > 1;

-- 2. Votes must point to an existing subject_offering.
select
  'votes_without_valid_subject_offering' as check_name,
  v.id,
  v.user_id,
  v.subject_id,
  v.subject_offering_id
from public.subject_difficulty_votes v
left join public.subject_offerings so on so.id = v.subject_offering_id
where so.id is null;

-- 3. Vote subject_id must match the offering subject_id.
select
  'votes_subject_mismatch' as check_name,
  v.id,
  v.user_id,
  v.subject_id as vote_subject_id,
  so.subject_id as offering_subject_id,
  v.subject_offering_id
from public.subject_difficulty_votes v
join public.subject_offerings so on so.id = v.subject_offering_id
where v.subject_id <> so.subject_id;

-- 4. Students can only vote for offerings from groups where they have or had enrollment.
select
  'votes_from_users_without_enrollment' as check_name,
  v.id,
  v.user_id,
  v.subject_offering_id,
  so.group_id
from public.subject_difficulty_votes v
join public.subject_offerings so on so.id = v.subject_offering_id
where not exists (
  select 1
  from public.student_enrollments se
  where se.user_id = v.user_id
    and se.group_id = so.group_id
);

-- 5. Profile orphan checks. FKs should prevent rows here.
select
  'subject_profiles_without_subject_id' as check_name,
  ssp.id,
  ssp.subject_id
from public.subject_student_profiles ssp
left join public.subject_catalog sc on sc.id = ssp.subject_id
where sc.id is null;

select
  'offering_profiles_without_subject_offering_id' as check_name,
  sosp.id,
  sosp.subject_offering_id
from public.subject_offering_student_profiles sosp
left join public.subject_offerings so on so.id = sosp.subject_offering_id
where so.id is null;

-- 6. Schedule/lessons rows that still need alias mapping.
select
  'schedule_entries_without_mapping' as check_name,
  count(*) as rows_count
from public.lessons l
where coalesce(l.raw_subject_name, l.subject) is not null
  and nullif(trim(coalesce(l.raw_subject_name, l.subject)), '') is not null
  and l.alias_match_status = 'pending'
  and (l.subject_id is null or l.subject_offering_id is null);

-- 7. Ambiguous schedule aliases based on normalized lesson names that map to multiple subjects.
with lesson_names as (
  select distinct
    coalesce(l.normalized_subject_name, public.f_norm_subject(coalesce(l.raw_subject_name, l.subject))) as normalized_subject_name
  from public.lessons l
  where nullif(trim(coalesce(l.normalized_subject_name, l.raw_subject_name, l.subject)), '') is not null
),
alias_matches as (
  select
    ln.normalized_subject_name,
    count(distinct sa.subject_id) as matched_subjects
  from lesson_names ln
  join public.subject_aliases sa on sa.normalized_alias = ln.normalized_subject_name
  group by ln.normalized_subject_name
)
select
  'ambiguous_schedule_aliases' as check_name,
  normalized_subject_name,
  matched_subjects
from alias_matches
where matched_subjects > 1;

-- 8. Rows explicitly marked ambiguous.
select
  'schedule_entries_marked_ambiguous' as check_name,
  l.id,
  l.group_id,
  coalesce(l.raw_subject_name, l.subject) as raw_subject_name,
  l.normalized_subject_name,
  l.subject_id,
  l.subject_offering_id
from public.lessons l
where l.alias_match_status = 'ambiguous'
order by l.created_at desc nulls last
limit 100;

-- 9. Stats summary and cross-check against raw votes.
select
  'stats_summary_counts' as check_name,
  (select count(*) from public.subject_difficulty_votes) as raw_votes_count,
  (select coalesce(sum(votes_count), 0) from public.subject_difficulty_stats_global) as global_stats_votes_count,
  (select coalesce(sum(votes_count), 0) from public.subject_difficulty_stats_by_offering) as offering_stats_votes_count,
  (select count(*) from public.subject_student_profiles) as subject_profiles_count,
  (select count(*) from public.subject_offering_student_profiles) as offering_profiles_count;

-- 10. Future-semester votes, based on each group's current known semester.
with group_current_semesters as (
  select
    gts.group_id,
    max(gts.semester_number) as current_semester_number
  from public.group_term_semesters gts
  group by gts.group_id
)
select
  'future_semester_votes' as check_name,
  v.id,
  v.user_id,
  v.subject_offering_id,
  so.group_id,
  so.semester_number,
  gcs.current_semester_number
from public.subject_difficulty_votes v
join public.subject_offerings so on so.id = v.subject_offering_id
left join group_current_semesters gcs on gcs.group_id = so.group_id
where gcs.current_semester_number is null
   or so.semester_number > gcs.current_semester_number;
