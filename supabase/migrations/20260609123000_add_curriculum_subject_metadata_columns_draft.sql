-- DRAFT ONLY. Do not apply without separate confirmation.
--
-- These columns preserve VV 2024 curriculum metadata that exists in staging but
-- is not present in the current production curriculum_subjects schema.

alter table public.curriculum_subjects
  add column if not exists subject_index text null,
  add column if not exists block_name text null,
  add column if not exists control_form text null,
  add column if not exists department text null,
  add column if not exists subject_type text null,
  add column if not exists subject_kind text null,
  add column if not exists is_elective boolean not null default false,
  add column if not exists elective_module_code text null;

create index if not exists curriculum_subjects_subject_index_idx
  on public.curriculum_subjects (subject_index)
  where subject_index is not null;

create index if not exists curriculum_subjects_elective_module_code_idx
  on public.curriculum_subjects (elective_module_code)
  where elective_module_code is not null;
