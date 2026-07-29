# CURRENT_TASK

* Status: **STAGE_15_2_NEWS_AUDIENCE** / Stage 15.1 Codex **APPROVE**
* Active Stage: **15 — Home / News / Profile**
* Exact substage: **15.2** news audience extension (junctions + locked semantics)
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Done

* Docs gate Codex APPROVE
* Stage 14A SQL foundation Codex APPROVE
* Stage 14B + hotfix Codex APPROVE
* Stage 15.1 Home promo vertical slice Codex **APPROVE**
  * Dual-read Mobile + Admin editor + shared renderer
  * Residual: image_asset_id presentation deferred until media path

## Remaining (15.2)

* Extend news audience with `news_audience_groups` / `news_audience_users`
* Locked matching semantics (SPEC §15.2)
* Preview recipients + backward compatibility
* Tests + Codex plan → implement → full diff → APPROVE

## Migrations

* `20260729133000_stage14_managed_content_foundation.sql` — local only
* 15.2 will add a new local migration (not remote-applied)

## Tests

* 15.1 suite green locally
* Local Supabase CLI still BLOCKED (`supabase-go` missing)

## Codex verdict

* 15.1: **APPROVE**
* 15.2: pending plan audit

## Next step

1. Codex plan audit for 15.2
2. Implement news audience junctions locally
3. Tests → full diff → fix P0/P1 → APPROVE → local commit

## Hard bans

* No remote Supabase apply
* No Edge Function deploy
* No GitHub push
* No real data import
* No `service_role` in Flutter / Admin Web
