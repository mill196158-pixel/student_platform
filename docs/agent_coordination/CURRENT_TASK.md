# CURRENT_TASK

* Status: **DONE** — Stage 14.2.3 (home_promo schema 3 + chat CTA + in-place edit)
* Active Stage: **14.2.3**
* Branch: `refactor/chat-tab`
* Prior HEAD: `4720810`
* Feature SHA: `0e24c47`
* Codex plan: **APPROVE**
* Codex final: **APPROVE** (after template insert / chat picker / HTTPS / LIMIT fixes)
* Remote: `gwdanmwluhrcfxbnplwd`
* Migration applied: `20260731113816_stage14_2_3_home_promo_schema3_chat_cta`
* Edge: none
* Push: `origin/refactor/chat-tab` (`4720810..0e24c47`)

## Root cause (old promo)

Published `df88b378…` (schema 1, legacy_key `content:home_promo:stuck_with_assignment`) had open WD, but admin JSON only set `has_working_draft` without `working_draft` object → no overlay, fields stayed locked, archive/safe-delete blocked by `working_draft_exists`. Create minted second draft `dbabdc80…`.

## Smoke (no live deletes)

* home_promo placement count before/after: **2 / 2**
* both live cards unchanged
* WD object present in admin JSON for `df88b378…`
* schema upgrade helper allows 1→3
* HTTPS reject/accept corpus on SQL helper
