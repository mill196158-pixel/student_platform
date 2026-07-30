# CURRENT_TASK

* Status: **PATH A DONE** — merge+push complete; **PATH B WAITING** owner PITR confirm + Codex B GO
* Active Stage: production integration Stages 14–21
* Branch: `refactor/chat-tab` @ merge `0d879c5` (+ pending roleplay JWT claims fix)
* Content worktree: `/Users/annasuvorova/student_platform_content` @ `feature/content-platform`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no Edge deploy yet**)

## Done (Path A)

* Pushed `origin/feature/content-platform`
* Backup tag/branch @ `c31f572`
* Merged into `refactor/chat-tab` and pushed (`0d879c5`)
* Admin suite **157/157 PASS** post-merge
* Local Stage 16.1 / 16.2 / 16.3 roleplays **OK** (fixtures + `request.jwt.claims` fix)
* Security reviews Stage 14–19 PASS; Edge smoke runbook §11 locked

## Remaining for Path B

1. Owner confirms Dashboard → Database → Backups: restore point + retention for `gwdanmwluhrcfxbnplwd` (record in preflight §9)
2. Codex re-APPROVE Path B
3. Remote apply 22 migrations one-by-one + Edge deploy 3 + smoke §11
4. Web Admin + Mobile verify; acceptance docs; clean trees

## Hard bans until B APPROVE + PITR recorded

No remote migration apply · No Edge deploy · No real import · No force-push
