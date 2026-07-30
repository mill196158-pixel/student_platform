# CURRENT_TASK

* Status: **DONE** — Stage 14.1.1 (Visual Editor news-parity + working drafts)
* Active Stage: **none** (await owner next Content Platform substage)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd`
* Closeout: Codex **APPROVE** — migrations applied; commit/push pending this turn

## Applied migrations (remote)

1. `20260730155714_stage14_1_1_working_drafts_and_reference_blocks`
2. `20260730160328_stage14_1_1_working_draft_schema_upgrade`
3. `20260730161522_stage14_1_1_vacancy_draft_asset_visibility`

## Residuals (non-blocking)

* Authenticated media smoke JWT (owner-gated)
* `ADMIN_REFERENCE_V3_BLOCKS` remains default false until Mobile+Admin same-release enablement
* Edge deploy not required (SQL finalize path owns vacancy draft binding)

## Hard bans

* No edit of applied migrations / no force-push / no Edge deploy / no mass notify / no XLSX
