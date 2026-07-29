# CURRENT_TASK

* Status: **STAGE_14A_SQL_FOUNDATION** / docs gate Codex **APPROVE_WITH_NOTES**
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (read-only; no apply)

## Active substage

Stage 14A — local SQL foundation only:

* tables, constraints, indexes
* fail-closed PL/pgSQL payload validator
* audience + concurrency helpers
* RLS / FORCE / grants
* Admin + mobile RPC foundations
* SQL security + behavioral role-play tests

Notes from docs APPROVE:

* `admin_reorder_content_placement` requires expected `row_version` for every affected item; deterministic locks; full rollback on conflict
* `admin_create_content_draft` is the exception (no prior row_version)

## Out of scope this slice

* Dart models / renderers (Stage 14B)
* Home promo UI wiring (15.1)
* Remote apply / Edge deploy / push / real import

## Constraints

* No remote migration apply
* No Edge deploy
* No GitHub push
* No service_role in Web
* Do not edit already-applied migrations

## Next gate

Implement → tests → Codex review of full diff → fix P0/P1 → APPROVE → local commit → Stage 14B typed Dart models
