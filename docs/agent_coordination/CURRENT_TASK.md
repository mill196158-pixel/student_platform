# CURRENT_TASK

* Status: **READY TO CLOSE** — Stage 14.1.4 (Full Visual Parity & Media Reliability)
* Active Stage: **14.1.4 / M5**
* Branch: `refactor/chat-tab`
* Base HEAD was: `7a96ccc`
* Codex final: **APPROVE** (after multi-slot Home P1 fixes)
* Remote: `gwdanmwluhrcfxbnplwd`
* Gate: `content_visual_studio_v2_publish` remains **OFF**
* Migration applied: `20260731000318_stage14_1_4_vacancy_assets_role_in_get_my`

## Done

* ContentImageRenderState — no silent image_* → gradient_text
* Mobile media key `userScope|assetId|contentVersion` + single-flight + generation isolation
* HomePromoService ordered multi-slot; per-card tap/dismiss/impressions
* Admin full-screen Home/Profile/Help/Jobs via student_ui
* Custom icon upload independent of hero; iconBytes painted with BoxFit.contain
* Vacancy logo/cover/background Admin + mobile hydrate; get_my_vacancies exposes role
* Tests/builds green; controlled smoke before=after counts (vacancies=3 published=0 assets=0)

## Next after closeout

* Stage 14.1.5 / next Content Platform substage per roadmap (owner)
