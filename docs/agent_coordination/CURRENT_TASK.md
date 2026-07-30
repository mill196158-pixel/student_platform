# CURRENT_TASK

* Status: **DONE** — Stage 14.1.2 (Visual Content Studio)
* Active Stage: **14.1.2 complete** → next: Import Studio audit (separate stage)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd`
* Final gate: Codex **APPROVE_WITH_NOTES** (2026-07-31)

## Locked contracts (Codex) — closed

1. Promo/profile **schema v2** additive; **server publish gate defaults OFF** until Mobile compatible release.
2. CTA = structured `action` + derived legacy `cta_route`/`cta_url` aligned Admin/SQL/Mobile (`/home`, `/my-diary`, `/help`).
3. `home_slot` in payload; default `after_assignments`.
4. Visual assets join ownership / `draft_asset_ids`.
5. `vacancy_assets.role` constrained.
6. Category delete: reassign | archive_articles | cancel; tombstone by `legacy_key`.
7. Audience lens RPC present (Admin UI hook = residual NOTE).
8. Import Studio: docs-only next-stage note.

## Applied migrations

* `20260730190415_stage14_1_2_visual_content_studio`
* `20260730220218_stage14_1_2_action_routes_category_tombstone` (P1 follow-up)

## Residuals (non-blocking NOTES)

* Custom `icon_asset_id` upload UX incomplete (catalog IconPicker works)
* Vacancy logo/cover/bg role pickers not fully in Admin UI
* `admin_preview_content_audience_lens` UI not wired
* Publish gate stays OFF until Mobile release

## Next

1. Import Studio multi-format curriculum audit (separate stage)
2. Do not enable `content_visual_studio_v2_publish` without owner + Mobile

## Hard bans

* No edit of applied migrations / no force-push / no Edge deploy / no mass notify
* No Import Studio rewrite in this closeout
