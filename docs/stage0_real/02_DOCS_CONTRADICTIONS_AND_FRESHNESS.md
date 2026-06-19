# 02 Docs Contradictions And Freshness

This file records contradictions without guessing. Each item needs code or live DB verification.

## Import Completion

- Source A says: `docs/vv_2024_staging_import.md` says the step is only preliminary staging and does not insert into `public.users`, `groups`, `subject_catalog`, `curriculum_subjects`, `subject_offerings`, or create Auth users.
- Source B says: `docs/legacy_to_new_academic_migration_notes.md` says Auth users were created, `public.users` filled, `student_enrollments` created, `subject_catalog`, `subject_aliases`, `curriculum_subjects`, `subject_offerings` created, and current-semester teams/chats created.
- Live DB verification: confirmed production rows exist: `users=34`, `student_enrollments=29`, `subject_catalog=27`, `subject_aliases=27`, `curriculum_subjects=31`, `subject_offerings=54`, `teams=12`, `chats=16`, `team_members=190`, `chat_members=198`.
- Stage 0 conclusion: staging-only docs are outdated as current-state docs, but still useful as safety/process docs.

## RLS State

- Source A says: `docs/academic_rls_and_visibility_plan.md` says new academic tables had RLS disabled and RLS draft was not applied.
- Source B says: later import docs imply the system moved beyond pre-import stages, but do not prove final RLS was applied.
- Live DB verification: many academic tables still have RLS disabled and zero policies: `groups`, `student_enrollments`, `academic_years`, `academic_terms`, `group_academic_profiles`, `group_term_semesters`, `subject_catalog`, `subject_aliases`, `curriculum_subjects`, `subject_offerings`, `teachers`, `offering_teachers`, rating/profile tables. This is a critical risk, but Stage 0 did not apply any remediation.
- Stage 0 conclusion: RLS remains a required security stage before broad frontend reliance on exposed academic tables.

## Migration Timeline

- Source A says: `docs/migration_status_2026_06_08.md` says only migration 001 and 002 were applied, no backfill/RPC/functions were created, and next stage was RLS/security audit before backfill.
- Source B says: `docs/legacy_to_new_academic_migration_notes.md` says the VV 2024 import checklist is complete and post-checks are clean.
- Live DB verification: production academic tables, staging rows, and RPCs exist. Found RPC names include `get_my_teams`, `get_my_lessons`, `get_my_subject_diary`, `rpc_get_my_subjects_v2`, `rpc_vote_subject_difficulty_v2`, `send_chat_message`, `get_team_assignments`, and assignment/chat helpers.
- Stage 0 conclusion: `migration_status_2026_06_08.md` is an older snapshot.

## `group_name` Versus `subject_offering_id`

- Source A says: architecture docs say `users.group_name` and `teams.group_name` are legacy compatibility only and new flows should use `student_enrollments.group_id` and `subject_offering_id`.
- Source B says: current Flutter code still has `LearningScreen.getCurrentGroupCodeSync()` returning hardcoded `1-См(ВВ)-1` and `SupabaseLearningRepository._mapRowToTeam()` maps `group_name`.
- Live DB verification: `teams`, `chats`, `assignments`, `chat_files`, `lessons`, and `subject_diary_entries` have `subject_offering_id` columns, but current Flutter is mixed: study plan uses `subject_offerings`, while team/chat flows still use team-centric RPCs and legacy fields.
- Stage 0 conclusion: model exists, frontend migration is partial.

## Chat FAQ Freshness

- Source A says: `docs/CHAT_FAQ.md` says message deletion deletes message and associated files from `chat_files`.
- Source B says: current `SupabaseLearningRepository.deleteMessage()` updates `chat_files.message_id = null` before deleting the message, so files remain available in the Files tab.
- Stage 0 conclusion: chat FAQ is useful but partially stale.

## Snapshot Folder Naming

- Source A says: the Stage 0 request asks the snapshot script to create `C:\student_platform\docs_snapshots`.
- Source B says: the allowed file list and final allowed-change check allow `docs/_snapshots/*`.
- Stage 0 action: used `docs/_snapshots` to stay within the allowed Stage 0 change set.
