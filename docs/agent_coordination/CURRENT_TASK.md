# CURRENT_TASK

* Status: **DONE** — Stage 14.2.1 (content-media working-draft upload on published items)
* Active Stage: **14.2.1** (hotfix after 14.2 / M7)
* Branch: `refactor/chat-tab`
* Prior HEAD: `43fffa3` (14.2 docs closeout)
* Codex plan: **APPROVE**
* Codex final: **APPROVE** (after reference WD row_version + transactional roleplay P1 fixes)
* Remote: `gwdanmwluhrcfxbnplwd`
* Migration applied: `20260731102302_stage14_2_1_content_asset_upload_working_draft`
* Edge deployed: `content-media` v2 (`verify_jwt=false`, BusinessError 409/422)

## Cause

`admin_create_content_asset_upload_intent` required `content_items.status = 'draft'`. Published cards keep `published` while edits live in `content_item_working_drafts`, so Edge surfaced `draft_only` as HTTP 500.

## Lifecycle (fixed)

`published → working draft → upload (bound to WD) → preview local bytes → save draft → publish → students see new asset`

* No upload into published without open working draft (`working_draft_required` / 409)
* Cancel WD keeps published image; orphan assets → cleanup
* Admin adopts `working_draft_row_version` from finalize before next save

## Smoke evidence (remote, disposable BEGIN/ROLLBACK)

* helper + intent columns present
* published without WD → `working_draft_required`
* published + WD → intent `bound_to_working_draft=true`
* leftover smoke items = 0; published_count unchanged; users_count unchanged

## Delivered

* Migration: WD bind columns + `content_assert_asset_upload_allowed` + create/finalize RPCs
* Edge: map business codes to 409/422/403/404 (not 500)
* Admin Home/Profile/Reference: `uploadBytesDetailed` + adopt draft RV + keep local preview
* Roleplay check + unit test; Admin/mobile tests; Web/Android/iOS builds
