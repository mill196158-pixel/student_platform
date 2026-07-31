-- Short admin-filled bio shown on teacher profile as «О преподавателе».
-- Leave null/blank to hide the block in the app.

alter table public.teacher_difficulty_targets
  add column if not exists about_text text;

comment on column public.teacher_difficulty_targets.about_text is
  'Optional short bio filled by admins. Shown in app as «О преподавателе» when non-empty.';
