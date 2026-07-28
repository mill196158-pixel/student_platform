# CURRENT_TASK

* Status: **STAGE_13_12_DONE** / Codex **APPROVE** (15/15)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote project: `gwdanmwluhrcfxbnplwd`
* PR: https://github.com/mill196158-pixel/student_platform/pull/1
* Remote migration: `20260728165633_stage13_12_group_action_cards_unified_details`

## Stage 13.12 closeout

* Card envelope parser + body/content split in `get_chat_messages_page`
* Batch card cache (no N+1) + Realtime bind/unbind lifecycle
* TopicSelection / Collection chat cards + UnifiedTaskDetailsScreen
* Deep topic editor (draft review + published options editor)
* Schedule/push/deeplink → details; Assignments tab unified list
* Topic option mutators with `row_version` / audit
* Remote apply + roleplay PASS; messages count 261 unchanged
* KeyboardDismissScope 13.11.1 preserved
* Edge not redeployed

## Residuals (owner)

* **PHYSICAL OCR SMOKE REQUIRED** — Android/iPhone
* **TWO-DEVICE TOPIC RACE REQUIRED**
* **CONTROLLED PUSH REQUIRED** — one real group-action notification path on device
* **REAL XLSX REQUIRED** — production imports (dry-run first; no fixtures)

## Constraints

* No force-push
* No teacher-media deploy until explicitly requested
* Do not create autumn 2026 / do not flip current term without explicit owner OK
