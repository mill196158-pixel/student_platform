# CURRENT_TASK

* Status: **DONE** — Stage 14.1.3 (Visual Editor Fidelity & Media Pipeline)
* Active Stage: **14.1.3** (closing out)
* Branch: `refactor/chat-tab`
* Codex: **APPROVE** (2026-07-31) — WD visual-role isolation + snapshot-after-reconcile
* Remote: `gwdanmwluhrcfxbnplwd`
* Gate: `content_visual_studio_v2_publish` remains **OFF**

## Delivered

1. Unified preview precedence + PreviewMode (`effectiveDraft` / `publishedCanonical`)
2. ContentIconResolver + 7 card variants + imageBytes in student_ui
3. Media intent states; home resolve generation-safe
4. Home / Profile / Reference / Vacancy live draft overlay
5. Vacancy visual roles with WD isolation (`admin_set_vacancy_asset_role`, `admin_clear_vacancy_visual_role`, publish reconcile)
6. Migration `20260730225652_stage14_1_3_vacancy_asset_role_rpc.sql` (controlled apply)

## Next

* Import Studio stage (separate) — do not rewrite Import Studio here
* Owner residuals: Edge/media smoke JWT; enable v2 publish gate only after Mobile client proof

## Hard bans (still)

* No edit of applied migrations / no force-push / no mass publish
* No enable `content_visual_studio_v2_publish` without Mobile proof
* No Import Studio rewrite
