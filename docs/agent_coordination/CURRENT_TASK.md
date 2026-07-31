# CURRENT_TASK

* Status: **DONE** — Stage 14.2.2 (reliable Visual Content Studio publish)
* Active Stage: **14.2.2**
* Branch: `refactor/chat-tab`
* Prior HEAD: `879cec8`
* Codex plan: **APPROVE**
* Codex final: **APPROVE** (after `profile_feed_card_v1` template-key fix)
* Remote: `gwdanmwluhrcfxbnplwd`
* Migration applied: `20260731110419_stage14_2_2_home_profile_schema_upgrade_wd`

## Exact server error

`invalid_schema_upgrade` on `admin_save_content_working_draft` when Admin sent `target_schema_version: 2` for published `home_promo_v1` / `schema_version=1` cards. Unmapped → «Не удалось выполнить операцию». Audit showed media finalize / begin_edit but almost no save/publish WD.

## Pipeline (fixed)

`validate → pending media (via autosave) → save WD → publish with saved draft RV → refetch`

Single-flight `VisualEditorPublishCoordinator` for Home / Profile / Reference / Vacancy.

## Smoke

* helper allows `home_promo_v1` and `profile_feed_card_v1` 1→2
* disposable save with `target_schema_version=2` succeeds then rolls back
* published fixture remains schema 1; published_count=10
