# CURRENT_TASK

* Status: **INTEGRATION BLOCKED — Codex 403** (cannot get APPROVE for push/merge/apply)
* Active Stage: production integration Stages 14–21 — paused before dangerous actions
* Branch: `feature/content-platform` @ `1392981` (ahead of `origin/refactor/chat-tab`, behind 0)
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push yet**)

## Ready locally (P1 gates closed pending Codex re-APPROVE)

* Preflight: `docs/content_platform/INTEGRATION_PREFLIGHT_2026_07_30.md`
* Admin suite **157/157 PASS**
* Local disposable DB: all 22 Stage 14–19 migrations applied; Stage 14 roleplay PASS; 15.2/17/19 security PASS
* Remote read-only: tip `stage13_12_11`; before-counts recorded; none of 22 applied
* Android debug + iOS simulator builds PASS
* Dashboard production copy fixed; news cache test fixed

## Blocker

Codex CLI returns **HTTP 403** from OpenAI (`Unable to load site` / Ray IDs in HEL). Per rules: do **not** push, merge, remote-apply, or Edge-deploy without Codex APPROVE after CHANGES_REQUESTED.

## Next (when Codex reachable)

1. Resume Codex integration re-review → APPROVE
2. Push `feature/content-platform`
3. Backup tag on `refactor/chat-tab`
4. Merge into main worktree → tests → push
5. Remote apply 22 migrations one-by-one + Edge deploy 3 functions + smoke

## Hard bans until APPROVE

No remote migration apply · No Edge deploy · No GitHub push · No merge · No real import
