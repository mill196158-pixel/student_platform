# CURRENT_TASK

* Status: **DONE** — Stage 14.1.5 (Final Visual Preview Integrity)
* Active Stage: **14.1.5 / M6**
* Branch: `refactor/chat-tab`
* Base HEAD: `690cd76`
* Codex final: **APPROVE** (after published-mode + sort P1 fixes)
* Remote: `gwdanmwluhrcfxbnplwd`
* Gate: `content_visual_studio_v2_publish` remains **OFF**
* Migration/Edge: none

## Root cause

`image_full` / `image_overlay` collapsed under unbounded `CustomScrollView` because ready `_PromoImagePlane` used `SizedBox(height: null)` with expanding stacks. `image_top_text` always used height 140.

## Done

* Invariant 180px bleed geometry for full/overlay (ready/loading/missing/failed)
* HomePromoPayload overlay/focal/image_fit dual-read
* Admin placements: published mode keeps published cards; draft overlay only in live mode; id tie-break sort
* Shared `StudentProfileScreenPreview` on Admin + Mobile
* Human banners; Stage/schema in Diagnostics
* Parameterized + golden tests 390×844 / 430×932
