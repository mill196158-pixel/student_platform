# CURRENT_TASK

* Status: **STAGE_14B_DART_MODELS** / Stage 14A Codex **APPROVE**
* Active Stage: **14 — Managed Content Platform**
* Exact substage: **14B** typed Dart models + shared renderer stubs (after 14A commit)
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply**)

## Done

* Docs gate Codex APPROVE
* Stage 14A SQL foundation Codex **APPROVE**
* Migration `20260729133000_stage14_managed_content_foundation.sql`
* Security + roleplay checks authored
* Local Supabase CLI preflight BLOCKED (supabase-go missing) — documented residual

## Remaining (14B)

* Typed models in `packages/student_ui` (no raw JSON in UI)
* Shared Home promo renderer stub Mobile ↔ Admin Preview
* Focused Dart tests
* Codex review → APPROVE → local commit → Stage 15.1 vertical slice

## Migrations

* `20260729133000_stage14_managed_content_foundation.sql` — local only, not remote-applied

## Hard bans

* No remote apply / Edge deploy / push / real import / service_role in Web
