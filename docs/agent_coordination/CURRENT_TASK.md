# CURRENT_TASK

* Status: **PATH A DONE** · logical backup **full-restore verified** · Codex Path B re-GO pending
* Active Stage: production integration Stages 14–21
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd`
* Backup: `/Users/annasuvorova/student_platform_backups/pre_content_platform_20260730_133051/` (outside Git; `0700`/`0600`)

## Done

* PITR/paid add-ons replaced by free verified logical backup (owner decision)
* Full disposable restore roles→schema→data **PASS** (counts + FK orphans=0)
* Preflight §9 updated

## Next

1. Codex Path B GO without PITR
2. Apply 22 migrations one-by-one + Edge deploy 3 + smoke §11
3. No mass import / demo publish / push

## Hard bans until Codex Path B APPROVE

No remote migration apply · No Edge deploy · No PITR/Pro/compute · No real import
