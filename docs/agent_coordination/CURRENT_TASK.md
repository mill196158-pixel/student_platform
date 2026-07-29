# CURRENT_TASK

* Status: **STAGE_16_19_FOUNDATION_REWORK** / Codex partial: 17+18 APPROVE_WITH_NOTES; 16+19 pending re-review after P1 fixes
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Approved chain (local commits)

| Slice | Status | Commit |
|---|---|---|
| Docs gate | APPROVE | `9c8aba9` / `d1796ac` |
| 14A SQL | APPROVE | `2588581` |
| 14B models | APPROVE | `691f43e` / `74c779d` |
| 15.1 Home promo | APPROVE | `183efc8` |
| 15.2 News audience | APPROVE | `001e1f0` |
| 15.3 Profile feed | APPROVE | `cebfcf5` |
| 20 AI spec | APPROVE | `e279c53` |
| 21 RF roadmap | APPROVE | `e279c53` |

## Active

Stage 16–19 SQL foundation drafts (local only):

* **17 + 18**: Codex **APPROVE_WITH_NOTES** as FOUNDATION DRAFT — may commit labeled as draft
* **16**: P1 rework — asset version race fixed (lock + unique current/version indexes); 16.1 UI/concurrency residuals remain
* **19**: P1 rework — rollback returns structured refusal so audit survives

## Hard bans

No remote apply / Edge deploy / push / real import / service_role in Web

## Next gate

1. Codex re-review 16 + 19 after latest P1 patches
2. Local commit 17+18 FOUNDATION DRAFT (and 16/19 if APPROVE)
3. Overall chain review
4. Owner: remote apply / deploy / push
