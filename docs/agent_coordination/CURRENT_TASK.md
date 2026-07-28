# CURRENT_TASK

* Status: STAGE_13_11_CODE_READY — awaiting Codex thread APPROVE + Supabase MCP auth for remote apply / live 24002820 audit
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote project: `gwdanmwluhrcfxbnplwd`
* PR: https://github.com/mill196158-pixel/student_platform/pull/1
* Local HEAD: Stage 13.11 migration `20260728105753_stage13_11_membership_capabilities_ux` (not remote-applied)

## Stage 13.11 blockers (owner / desktop auth)

* Codex CLI/MCP not authenticated in this cloud agent (`codex login` required; thread resume unavailable).
* Supabase MCP `needsAuth` — interactive OAuth only in Cursor desktop IDE. Blocks live audit of `24002820` and controlled remote apply.

## Done technically

* Remote migrations applied (aligned local filenames → remote versions):
  * `20260727183823_admin_news_archive_delete`
  * `20260727184049_stage13_2_group_space`
  * `20260727184156_stage13_3_teachers_admin`
  * `20260727184238_stage13_4_subjects_admin`
  * `20260727184423_stage13_5_students_groups_terms_admin`
  * `20260727184457_stage13_6_reviews_moderation`
  * `20260727184511_stage13_2_admin_group_organizer` (after 13.5)
  * `20260727234755_stage13_8_safe_academic_terms`
  * `20260727235000_stage13_9_chat_topics_collections`
  * `20260727235317_stage13_9_group_action_notifications`
  * `20260727235707_stage13_9_fix_card_msg_type` (card `msg_type` text hotfix)
  * `20260728000451_stage13_8_fix_lifecycle_search_path` (search_path hardening)
  * `20260728101245_stage13_10_group_actions_ux`
* Stage 13.10: composer capabilities matrix, subject-only topics, group_space collections («Скинуться»), assignment RPC harden, collection FSM + `organizer_comment`, legacy group_space topic cancelled
* Local: ephemeral assignments baseline + full behavioral roleplay PASS; security review PASS
* Remote: assertive security PASS; BEGIN…ROLLBACK behavioral smoke PASS; counts unchanged (assignments=4, votes=8, messages=259, teams=20, outbox backlog=0)
* Edge `dispatch-push-notifications` **v5** ACTIVE — **not redeployed** in 13.10 (unchanged)
* Current term unchanged: **весна 2026**; autumn 2026 not created; pending outbox = 0

## Residuals (non-technical / owner)

* **PHYSICAL OCR SMOKE REQUIRED** — Android/iPhone
* **TWO-DEVICE TOPIC RACE REQUIRED**
* **CONTROLLED PUSH REQUIRED** — one real group-action notification path on device
* **REAL XLSX REQUIRED** — production imports (dry-run first; no fixtures)

## Constraints

* No force-push
* No teacher-media deploy until explicitly requested
* Do not create autumn 2026 / do not flip current term without explicit owner OK
