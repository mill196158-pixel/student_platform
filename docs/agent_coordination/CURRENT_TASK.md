# CURRENT_TASK

* Status: **READY TO CLOSE** — Stage 14.1 + Design Z (visual editors + demo bootstrap)
* Active Stage: **14.1 + Design Z**
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd`
* Remote migration: `20260730144804_stage14_1_demo_bootstrap_legacy_keys` **applied**
* Bootstrap: **applied** (idempotent re-run = 18× `skip_existing`)

## Done

* Audit: Demo Admin = Local\*Repository seeds; Real Admin was empty Supabase tables
* Inventory bootstrapped 1:1 from Mobile (existing only):
  * home promo ×1 published (`content:home_promo:stuck_with_assignment`)
  * profile feed ×3 published
  * reference categories ×5 + articles ×6 published
  * vacancies ×3 draft `origin=demo`
* Residual (not bootstrapped): `subject_info_screen._HelpCard`
* Shared `VisualEditorShell` + phone preview using `student_ui` widgets
* Editors: Home promo / Profile feed / Reference / Vacancies — news-parity 3-pane
* Demo/Real fail-closed: Real mode never falls back to Local when Supabase missing (`AdminContentBackend`)
* Dashboard Real Admin: bootstrap dry-run → apply; blocks on conflicts
* Menu: «Карточки главной»; sections Участники/Модерация
* Checks: roleplay + security review (identity args accepts `boolean` / `p_dry_run boolean`)

## Remote counts (after bootstrap)

| Table | Count |
|---|---|
| content_items | 10 (published, origin=demo) |
| vacancies | 3 (draft, origin=demo) |
| reference_categories | 6 (1 seed `general` + 5 demo) |
| content_item_placements | 10 |
| content_item_versions | 10 |
| vacancy_versions | 3 |
| content_legacy_tombstones | 0 |
| users / messages / news_posts | 34 / 261 / 3 (unchanged) |

## Residuals

* Authenticated media smoke needs runtime JWT (no secrets in agent)
* Vacancy tags/accentColor remain student_ui presentation-only
* deno not on PATH for Edge check (no new Edge Functions in this slice)

## Hard bans still active until owner lifts

* No mass publish push / no XLSX import / no force-push / no editing applied migrations
