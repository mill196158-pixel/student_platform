# CURRENT_TASK

* Status: **INTEGRATION IN PROGRESS** — Codex path A GO; path B pending green checks + PITR + Edge runbook re-APPROVE
* Active Stage: production integration Stages 14–21
* Branch: `feature/content-platform` (pushed)
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no Edge deploy yet**)

## Done

* Preflight: `docs/content_platform/INTEGRATION_PREFLIGHT_2026_07_30.md` (Edge smoke runbook §11)
* Admin suite **157/157 PASS**; Android/iOS builds PASS
* Local disposable DB: all 22 Stage 14–19 migrations applied
* Security reviews Stage 14–19 **PASS** after aligning checks with `private.*` helpers
* Pushed `origin/feature/content-platform`
* Backup tag `backup/pre-content-platform-20260730` @ `c31f572`
* Backup branch `backup/refactor-chat-tab-pre-content-20260730` pushed

## Next

1. Codex re-review after check + preflight updates → APPROVE for B (or confirm A still GO)
2. Merge `feature/content-platform` → `refactor/chat-tab` (main worktree) → retest → push
3. Confirm Dashboard PITR / retention for `gwdanmwluhrcfxbnplwd`
4. Remote apply 22 migrations one-by-one + Edge deploy 3 functions + smoke §11
5. Web Admin + Mobile verify; update acceptance docs; clean trees

## Hard bans until B APPROVE + PITR confirmed

No remote migration apply · No Edge deploy · No real import · No force-push
