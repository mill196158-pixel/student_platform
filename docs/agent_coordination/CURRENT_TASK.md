# CURRENT_TASK

* Status: **STAGE_16_SUBJECTS** / Stage 15.3 Codex **APPROVE**
* Active Stage: **16 — Subjects & reference**
* Exact substage: **16.1** subject card editor (starting)
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Done

* Stage 15.1 APPROVE + commit `183efc8`
* Stage 15.2 APPROVE + commit `001e1f0`
* Stage 15.3 profile feed Codex **APPROVE** (local commit pending)

## Remaining

* Local commit 15.3
* Stage 16.1 subject card editor
* Stage 16.2 subject files
* Stage 16.3 reference
* Then Stage 17+

## Changed files (15.3)

* `packages/student_ui` profile feed models/renderer/tests
* `lib/src/ui/profile/profile_feed_service.dart` + `profile_screen.dart`
* `lib/src/services/auth_service.dart` (logout clears feed cache)
* `admin_console/.../profile_feed/*` + router/shell/dashboard
* tests: `test/profile_feed_service_test.dart`, `admin_console/test/profile_feed_editor_test.dart`
* `docs/content_platform/ACCEPTANCE_CHECKLIST.md` §P
* `docs/agent_coordination/CURRENT_TASK.md`

## Migrations

* None for 15.3 (Stage 14 seed `profile_feed_card_v1`)

## Tests

* profile feed suites PASS (mobile + admin)
* Local Supabase CLI still BLOCKED

## Codex verdict

* 15.3: **APPROVE**

## Next step

* Local commit 15.3, then implement Stage 16.1

## Hard bans

* No remote Supabase apply
* No Edge deploy
* No GitHub push
* No real data import
* Do not mark checklist `[x]` without code + tests + Codex APPROVE
