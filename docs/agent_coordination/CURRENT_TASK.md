# CURRENT_TASK

* Status: **PATH A DONE** · Path B gate = **verified logical backup** (no PITR) · Codex re-GO pending
* Active Stage: production integration Stages 14–21 — remote apply after Codex APPROVE
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd`

## Done

* Path A merge+push complete
* Free logical backup (CLI 2.109.1):  
  `/Users/annasuvorova/student_platform_backups/pre_content_platform_20260730_133051/`  
  schema + data + roles; SHA-256 + structural `psql` verify + restore runbook; outside Git
* PITR / paid add-ons: **explicitly not used**
* Preflight §9 updated to logical-backup gate

## Next

1. Codex Path B GO **without PITR** (logical backup evidence)
2. Apply 22 missing migrations one-by-one with before/after counts + security checks
3. Deploy only `content-media`, `subject-media`, `vacancy-media` + smoke §11
4. No mass import / demo publish / push blast

## Hard bans until Codex Path B APPROVE

No remote migration apply · No Edge deploy · No PITR/Pro/compute upgrades · No real import
