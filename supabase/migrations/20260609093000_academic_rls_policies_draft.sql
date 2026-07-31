-- DRAFT ONLY. DO NOT APPLY WITHOUT REVIEW.
-- Academic RLS policy draft for the migration_001/migration_002 schema.
--
-- Goals:
-- - Enable RLS on new academic tables in public schema.
-- - Keep direct client-side writes blocked by default for academic structure.
-- - Allow authenticated students to read only their active group context and
--   subject offerings through student_enrollments.
-- - Allow authenticated users to read reference catalogs needed by the UI.
-- - Allow admins to manage academic structure through an existing users.role
--   admin model. Supabase service_role bypasses RLS and does not need policies.
--
-- Review points before applying:
-- - Confirm public.users.role = 'admin' is the intended admin model.
-- - Confirm old Flutter screens do not need direct reads from newly protected
--   tables before v2 RPCs are available.
-- - Confirm whether curriculum_subjects should be globally readable or only
--   group-scoped through subject_offerings in v2 RPCs.

begin;

alter table public.academic_years enable row level security;
alter table public.academic_terms enable row level security;
alter table public.group_academic_profiles enable row level security;
alter table public.group_term_semesters enable row level security;
alter table public.group_name_history enable row level security;
alter table public.group_naming_profiles enable row level security;
alter table public.student_enrollments enable row level security;
alter table public.subject_catalog enable row level security;
alter table public.subject_aliases enable row level security;
alter table public.subject_alias_review_queue enable row level security;
alter table public.curriculum_subjects enable row level security;
alter table public.subject_offerings enable row level security;
alter table public.teachers enable row level security;
alter table public.offering_teachers enable row level security;

-- Public academic calendar/reference reads for signed-in users.
create policy "academic_years_read_authenticated"
on public.academic_years
for select
to authenticated
using (true);

create policy "academic_terms_read_authenticated"
on public.academic_terms
for select
to authenticated
using (true);

create policy "subject_catalog_read_authenticated"
on public.subject_catalog
for select
to authenticated
using (true);

create policy "subject_aliases_read_authenticated"
on public.subject_aliases
for select
to authenticated
using (true);

create policy "curriculum_subjects_read_authenticated"
on public.curriculum_subjects
for select
to authenticated
using (true);

create policy "teachers_read_authenticated"
on public.teachers
for select
to authenticated
using (true);

-- Students can read only their own enrollment rows.
create policy "student_enrollments_read_own"
on public.student_enrollments
for select
to authenticated
using (user_id = auth.uid());

-- Students can read group academic metadata for their active group.
create policy "group_academic_profiles_read_active_group"
on public.group_academic_profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.student_enrollments se
    where se.group_id = group_academic_profiles.group_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

create policy "group_term_semesters_read_active_group"
on public.group_term_semesters
for select
to authenticated
using (
  exists (
    select 1
    from public.student_enrollments se
    where se.group_id = group_term_semesters.group_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

create policy "group_name_history_read_active_group"
on public.group_name_history
for select
to authenticated
using (
  exists (
    select 1
    from public.student_enrollments se
    where se.group_id = group_name_history.group_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

create policy "group_naming_profiles_read_active_group"
on public.group_naming_profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.student_enrollments se
    where se.group_id = group_naming_profiles.group_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

-- Students can read offerings for their active group. This allows the UI to
-- show current, archived, and future curriculum subjects without creating teams.
create policy "subject_offerings_read_active_group"
on public.subject_offerings
for select
to authenticated
using (
  exists (
    select 1
    from public.student_enrollments se
    where se.group_id = subject_offerings.group_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

create policy "offering_teachers_read_active_group_offerings"
on public.offering_teachers
for select
to authenticated
using (
  exists (
    select 1
    from public.subject_offerings so
    join public.student_enrollments se on se.group_id = so.group_id
    where so.id = offering_teachers.subject_offering_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

-- Alias review queue is operational/admin data; no regular user read policy.

-- Admin read/write policies. Direct client writes remain blocked for non-admin
-- users because no INSERT/UPDATE/DELETE policies are defined for them.
create policy "academic_years_admin_manage"
on public.academic_years
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "academic_terms_admin_manage"
on public.academic_terms
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "group_academic_profiles_admin_manage"
on public.group_academic_profiles
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "group_term_semesters_admin_manage"
on public.group_term_semesters
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "group_name_history_admin_manage"
on public.group_name_history
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "group_naming_profiles_admin_manage"
on public.group_naming_profiles
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "student_enrollments_admin_manage"
on public.student_enrollments
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "subject_catalog_admin_manage"
on public.subject_catalog
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "subject_aliases_admin_manage"
on public.subject_aliases
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "subject_alias_review_queue_admin_manage"
on public.subject_alias_review_queue
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "curriculum_subjects_admin_manage"
on public.curriculum_subjects
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "subject_offerings_admin_manage"
on public.subject_offerings
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "teachers_admin_manage"
on public.teachers
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "offering_teachers_admin_manage"
on public.offering_teachers
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

commit;
