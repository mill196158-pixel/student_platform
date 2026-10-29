-- Owner authorized anonymous access containment on 2026-10-28.
-- Authenticated grants and row data remain unchanged.
set local lock_timeout = '3s';
set local statement_timeout = '30s';

do $containment$
declare
  table_name text;
  table_id regclass;
  targets constant text[] := array[
    'academic_years', 'curriculum_subjects', 'group_academic_profiles',
    'group_name_history', 'group_naming_profiles', 'group_term_semesters',
    'groups', 'has_attachment', 'has_attachments', 'has_body',
    'has_topic', 'has_created_at', 'has_extension', 'has_is_pinned', 'has_reply_to',
    'lessons', 'offering_teachers', 'student_enrollments',
    'subject_alias_review_queue', 'subject_aliases',
    'subject_difficulty_votes', 'subject_offering_student_profiles',
    'subject_offerings', 'subject_ratings', 'teacher_ratings',
    'teacher_subject_ratings', 'team_autocreate_blacklist'
  ];
begin
  foreach table_name in array targets loop
    table_id := to_regclass(format('public.%I', table_name));
    if table_id is null then
      raise exception 'Schema drift: missing table %', table_name;
    end if;
    execute format('revoke all privileges on table public.%I from anon', table_name);
    if has_table_privilege('anon', table_id, 'SELECT')
       or has_table_privilege('anon', table_id, 'INSERT')
       or has_table_privilege('anon', table_id, 'UPDATE')
       or has_table_privilege('anon', table_id, 'DELETE')
       or has_table_privilege('anon', table_id, 'TRUNCATE')
       or has_table_privilege('anon', table_id, 'REFERENCES')
       or has_table_privilege('anon', table_id, 'TRIGGER')
       or has_any_column_privilege('anon', table_id, 'SELECT')
       or has_any_column_privilege('anon', table_id, 'INSERT')
       or has_any_column_privilege('anon', table_id, 'UPDATE')
       or has_any_column_privilege('anon', table_id, 'REFERENCES') then
      raise exception 'Anon privileges remain on %; review PUBLIC/role/column grants', table_name;
    end if;
  end loop;
end
$containment$;
