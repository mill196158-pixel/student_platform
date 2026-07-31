-- Read-only quality checks for VV 2024 staging imports.
-- Run after importing CSV files into:
--   public.stage_students_vv_2024
--   public.stage_curriculum_vv_2024
--
-- This file intentionally contains SELECT statements only.

-- 1. Students count by group.
select
  group_name,
  count(*)::bigint as students_count
from public.stage_students_vv_2024
group by group_name
order by group_name nulls first;

-- 2. Duplicate students by login.
select
  nullif(trim(login), '') as login,
  count(*)::bigint as duplicate_count,
  array_agg(source_row order by source_row) as source_rows
from public.stage_students_vv_2024
where nullif(trim(login), '') is not null
group by nullif(trim(login), '')
having count(*) > 1
order by duplicate_count desc, login;

-- 3. Duplicate students by record_book.
select
  nullif(trim(record_book), '') as record_book,
  count(*)::bigint as duplicate_count,
  array_agg(source_row order by source_row) as source_rows
from public.stage_students_vv_2024
where nullif(trim(record_book), '') is not null
group by nullif(trim(record_book), '')
having count(*) > 1
order by duplicate_count desc, record_book;

-- 4. Empty student names.
select
  id,
  source_row,
  record_book,
  login,
  surname,
  name,
  patronymic,
  full_name
from public.stage_students_vv_2024
where nullif(trim(coalesce(full_name, '')), '') is null
   or nullif(trim(coalesce(surname, '')), '') is null
   or nullif(trim(coalesce(name, '')), '') is null
order by source_row nulls last, id;

-- 5. Empty student groups.
select
  id,
  source_row,
  record_book,
  login,
  full_name,
  group_name
from public.stage_students_vv_2024
where nullif(trim(coalesce(group_name, '')), '') is null
order by source_row nulls last, id;

-- 6. Students where admission_year is not 2024.
select
  id,
  source_row,
  record_book,
  login,
  full_name,
  group_name,
  admission_year,
  source_admission_year
from public.stage_students_vv_2024
where admission_year is distinct from 2024
order by source_row nulls last, id;

-- 7. Students where current_semester_number is not 4.
select
  id,
  source_row,
  record_book,
  login,
  full_name,
  group_name,
  current_course,
  current_semester_number
from public.stage_students_vv_2024
where current_semester_number is distinct from 4
order by source_row nulls last, id;

-- 8. Curriculum disciplines count by group and semester.
select
  group_name,
  semester_number,
  count(*)::bigint as rows_count,
  count(*) filter (where coalesce(is_elective, false) = true)::bigint as elective_rows_count,
  count(*) filter (where coalesce(is_elective_module_header, false) = true)::bigint as elective_module_headers_count,
  count(*) filter (where coalesce(is_elective_option, false) = true)::bigint as elective_options_count
from public.stage_curriculum_vv_2024
group by group_name, semester_number
order by group_name nulls first, semester_number nulls first;

-- 9. Empty subject_name / display_name.
select
  id,
  source_row,
  group_name,
  semester_number,
  subject_index,
  raw_subject_name,
  display_name
from public.stage_curriculum_vv_2024
where nullif(trim(coalesce(raw_subject_name, '')), '') is null
   or nullif(trim(coalesce(display_name, '')), '') is null
order by source_row nulls last, id;

-- 10. Duplicate disciplines in the same group and semester.
select
  group_name,
  semester_number,
  coalesce(nullif(trim(subject_index), ''), '<empty>') as subject_index,
  lower(trim(coalesce(display_name, raw_subject_name, ''))) as normalized_subject_name,
  count(*)::bigint as duplicate_count,
  array_agg(source_row order by source_row) as source_rows
from public.stage_curriculum_vv_2024
where nullif(trim(coalesce(display_name, raw_subject_name, '')), '') is not null
group by
  group_name,
  semester_number,
  coalesce(nullif(trim(subject_index), ''), '<empty>'),
  lower(trim(coalesce(display_name, raw_subject_name, '')))
having count(*) > 1
order by duplicate_count desc, group_name, semester_number, normalized_subject_name;

-- 11. Electives list.
select
  id,
  source_row,
  group_name,
  semester_number,
  subject_index,
  raw_subject_name,
  display_name,
  block_name,
  control_form,
  credits_total,
  hours_total,
  elective_module_code,
  is_elective,
  is_elective_module_header,
  is_elective_option,
  include_in_subject_catalog,
  include_in_group_offerings_default
from public.stage_curriculum_vv_2024
where coalesce(is_elective, false) = true
   or coalesce(is_elective_module_header, false) = true
   or coalesce(is_elective_option, false) = true
order by group_name nulls first, semester_number nulls first, elective_module_code nulls first, import_order nulls last, id;

-- 12. Curriculum rows where admission_year is not 2024.
select
  id,
  source_row,
  group_name,
  subject_index,
  display_name,
  admission_year
from public.stage_curriculum_vv_2024
where admission_year is distinct from 2024
order by source_row nulls last, id;

-- 13. Curriculum rows where current_semester_number is not 4.
select
  id,
  source_row,
  group_name,
  subject_index,
  display_name,
  current_semester_number
from public.stage_curriculum_vv_2024
where current_semester_number is distinct from 4
order by source_row nulls last, id;
