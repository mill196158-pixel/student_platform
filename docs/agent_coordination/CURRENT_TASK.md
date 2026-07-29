# CURRENT_TASK

* Status: **STAGE_14A_SQL_FOUNDATION** / docs gate Codex **APPROVE**
* Active Stage: **14 — Managed Content Platform**
* Exact substage: **14A SQL foundation** (tables/constraints/validator/RLS/helpers/RPC stubs + SQL tests)
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (read-only; **no apply**)

## Done

* Docs gate Codex **APPROVE** (pass 4; P0/P1 none; P2 editorial applied)
* Control system: roadmap 14–21, SPEC, atomic checklist, AGENTS.md, `.cursor/rules/content-platform.mdc`
* Local docs snapshot commit `d1796ac` (+ pending commit for reorder/APPROVE closeout)

## Remaining (14A)

* Local migration: content tables, FORCE RLS, grants, templates seed
* PL/pgSQL fail-closed validators
* Audience/visibility + concurrency helpers
* Admin + mobile RPC foundations per SPEC
* SQL security + behavioral role-play tests
* Codex review of 14A diff → APPROVE → local commit

## Out of scope this slice

* Dart models / renderers (14B)
* Home promo UI (15.1)
* Remote apply / Edge deploy / push / real import

## Changed files (docs closeout, then 14A)

* `docs/content_platform/CONTENT_PLATFORM_SPEC.md`
* `docs/content_platform/ACCEPTANCE_CHECKLIST.md`
* `docs/agent_coordination/CURRENT_TASK.md`
* (+ upcoming `supabase/migrations/*stage14*` and SQL tests)

## Migrations

* Preparing locally only — **do not apply to remote**

## Tests

* Pending: SQL security + role-play for 14A

## Codex verdict

* Docs gate: **APPROVE**
* Stage 14A: not started review yet

## Next step

Implement Stage 14A SQL foundation → tests → Codex review

## Hard bans

* No remote Supabase apply
* No Edge deploy
* No GitHub push / force-push
* No real data import
* No service_role in Flutter Web
* No deleting existing production data
* No editing already-applied migrations
