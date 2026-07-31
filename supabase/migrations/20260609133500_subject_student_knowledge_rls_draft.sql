-- DRAFT ONLY. DO NOT APPLY WITHOUT SEPARATE REVIEW AND APPROVAL.
--
-- RLS draft for the student subject knowledge layer.
-- This file is intentionally separate from the schema/RPC migration because
-- enabling RLS can affect current clients. Review with the v2 Flutter flow first.

begin;

alter table public.subject_student_profiles enable row level security;
alter table public.subject_offering_student_profiles enable row level security;
alter table public.subject_difficulty_votes enable row level security;

-- Published global subject descriptions are readable by signed-in users.
create policy "subject_student_profiles_read_published_authenticated"
on public.subject_student_profiles
for select
to authenticated
using (moderation_status = 'published');

-- Published local offering descriptions are readable only to students of the
-- active group that owns the offering.
create policy "subject_offering_student_profiles_read_own_group_published"
on public.subject_offering_student_profiles
for select
to authenticated
using (
  moderation_status = 'published'
  and exists (
    select 1
    from public.subject_offerings so
    join public.student_enrollments se on se.group_id = so.group_id
    where so.id = subject_offering_student_profiles.subject_offering_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

-- Students can read only their own vote directly. Aggregate stats should be
-- consumed via RPC/views, not by exposing all raw comments.
create policy "subject_difficulty_votes_read_own"
on public.subject_difficulty_votes
for select
to authenticated
using (user_id = auth.uid());

-- Direct client writes to votes are intentionally not granted. Voting goes
-- through public.rpc_vote_subject_difficulty_v2, which validates enrollment,
-- current semester boundaries, and performs one-row-per-offering upsert.

-- Existing admin model used by academic_rls_policies_draft.sql.
create policy "subject_student_profiles_admin_manage"
on public.subject_student_profiles
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "subject_offering_student_profiles_admin_manage"
on public.subject_offering_student_profiles
for all
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'))
with check (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

create policy "subject_difficulty_votes_admin_read"
on public.subject_difficulty_votes
for select
to authenticated
using (exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'admin'));

-- Schedule matching draft for existing lessons table. This keeps visibility
-- group-scoped and does not expose alias review queue to regular users.
create policy "lessons_read_active_group_schedule"
on public.lessons
for select
to authenticated
using (
  exists (
    select 1
    from public.student_enrollments se
    where se.group_id = lessons.group_id
      and se.user_id = auth.uid()
      and se.status = 'active'
      and se.ended_at is null
  )
);

commit;
