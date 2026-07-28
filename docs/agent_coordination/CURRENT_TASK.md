# CURRENT_TASK

* Status: STAGE_13_8_AND_13_9_TECHNICALLY_DONE — physical OCR smoke + two-device topic race + controlled push remain
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote project: `gwdanmwluhrcfxbnplwd`

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
* Stage 13.8/13.9 security reviews PASS; notification role-play PASS after hotfix
* Edge `dispatch-push-notifications` **v5** ACTIVE (`verify_jwt=false`, custom bearer; unauth → 401)
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
