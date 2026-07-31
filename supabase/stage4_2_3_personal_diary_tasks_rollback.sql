-- Rollback for Stage 4.2.3 personal diary tasks.

drop policy if exists "personal_diary_tasks_delete_own" on public.personal_diary_tasks;
drop policy if exists "personal_diary_tasks_update_own" on public.personal_diary_tasks;
drop policy if exists "personal_diary_tasks_insert_own" on public.personal_diary_tasks;
drop policy if exists "personal_diary_tasks_select_own" on public.personal_diary_tasks;

drop table if exists public.personal_diary_tasks;
