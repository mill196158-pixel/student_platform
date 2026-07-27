# CURRENT_TASK

* Status: STAGE_13_2_TO_13_7_TECHNICALLY_DONE — physical smoke + real Excel remain
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
* Security reviews PASS; Edge Functions redeployed; Flutter/Admin tests PASS
* Organizer Admin UI: **Студенты** `/academic/students` → group chip → Организаторы пространства группы

## Residuals (non-technical / owner)

* **PHYSICAL SMOKE REQUIRED** — Android/iPhone
* **REAL XLSX REQUIRED** — production imports (dry-run first; no fixtures)

## Constraints

* No force-push
* No teacher-media deploy until explicitly requested
