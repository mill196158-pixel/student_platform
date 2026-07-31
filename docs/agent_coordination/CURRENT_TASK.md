# CURRENT_TASK

* Status: **DONE** — Stage 14.2 (Managed Content v2 → main mobile)
* Active Stage: **14.2 / M7**
* Branch: `refactor/chat-tab`
* Base HEAD: `be6ac42`
* Feature SHA: `ed94cb9`
* Codex plan: **APPROVE** (revised)
* Codex final: **APPROVE** (after action parse/typed-field P1 fixes)
* Remote: `gwdanmwluhrcfxbnplwd`
* Gate: `content_visual_studio_v2_publish` **ON** (owner SQL after smoke)
* Migration applied: `20260731122000_stage14_2_student_read_schema_wire_projection`
* Push: `origin/refactor/chat-tab` (`be6ac42..ed94cb9`)

## Smoke evidence (remote)

* Before: gate=false; home_v1=1; home_v2=0; profile_v1=3; profile_v2=0; vacancies_published=0; vacancies_non_published=3
* After projection migration + gate ON: same content counts; users_count=34; no deletes; no mass publish
* Wire projection verified in `get_my_content_for_placement`
* Vacancy assets still exclude `working_draft_id`

## Delivered

* Home schema 1|2 dual-read; ContentNavIntent whitelist; Mobile executor (tabs/diary/HTTPS/entity)
* Profile/Reference/Vacancy real surfaces + Info resume freshness
* Legacy-safe RPC wire schema_version 2→1 for home/profile
* Tests + Web/Android/iOS builds; commit + normal push
