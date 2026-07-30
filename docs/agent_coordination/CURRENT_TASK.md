# CURRENT_TASK

* Status: **PATH A DONE** · Codex **APPROVE_WITH_NOTES** · **PATH B blocked only on owner PITR record**
* Active Stage: production integration Stages 14–21
* Branch: `refactor/chat-tab` @ `ea02c2f` (= origin)
* Content worktree: `/Users/annasuvorova/student_platform_content` @ `feature/content-platform` `c465f67`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no Edge deploy yet**)

## Done

* Path A: push feature → backup → merge → push `refactor/chat-tab`
* Admin **157/157** post-merge
* Local 22 migrations + Stage 14–19 security PASS
* Stage 16.1 / 16.2 / 16.3 roleplays **OK**
* Edge smoke runbook §11 locked
* Codex #6: **APPROVE_WITH_NOTES** — Path B GO after PITR recorded in preflight §9

## Next (owner one-liner)

Confirm in Supabase Dashboard → Database → Backups for `gwdanmwluhrcfxbnplwd`:
* available restore point (timestamp), and
* retention window

Then say e.g. `PITR ok: <timestamp>, retention <N days>` — Cursor records it and applies Path B.

## Hard bans until PITR recorded

No remote migration apply · No Edge deploy · No real import · No force-push
