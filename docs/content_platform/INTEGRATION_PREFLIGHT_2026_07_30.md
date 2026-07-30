# Production integration preflight — Stages 14–21

Date: **2026-07-30** (refreshed after Codex CHANGES_REQUESTED)  
Content worktree: `/Users/annasuvorova/student_platform_content` @ `feature/content-platform`  
Main worktree: `/Users/annasuvorova/student_platform` @ `refactor/chat-tab`  
Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`  
Remote project: `gwdanmwluhrcfxbnplwd`

## 1. Git state

| Worktree | Branch | Status | Notes |
|---|---|---|---|
| content | `feature/content-platform` | clean after pending commit | **ahead of origin/refactor/chat-tab**; behind **0** (merged `c31f572`) |
| main | `refactor/chat-tab` | clean | equals `origin/refactor/chat-tab` @ `c31f572` |

## 2. Commits (feature vs origin/refactor/chat-tab)

26+ commits including Stage 14–21 chain, merge of `c31f572`, admin news-tab test fix, dashboard production copy, news-cache test fix.

## 3. Migrations to apply remotely (ordered, none yet on remote)

Remote migration tip: `20260729085151_stage13_12_11_picker_arrays_ordered` — **no Stage 14–19 versions present**.

1. `20260729133000_stage14_managed_content_foundation.sql`
2. `20260729140000_stage15_2_news_audience_extension.sql`
3. `20260729150500_stage16_1_subject_card_foundation.sql`
4. `20260729150550_stage16_1_subject_card_hardening.sql`
5. `20260729150560_stage16_1_subject_card_p1_r2.sql`
6. `20260729150570_stage16_1_subject_card_p1_r3.sql`
7. `20260729150600_stage16_2_subject_assets.sql`
8. `20260729150650_stage16_2_subject_assets_hardening.sql`
9. `20260729150660_stage16_2_subject_assets_p1_fixes.sql`
10. `20260729150670_stage16_2_subject_assets_p1_r2.sql`
11. `20260729150700_stage16_3_reference_corrections.sql`
12. `20260729150750_stage16_3_reference_hardening.sql`
13. `20260729150760_stage16_3_content_media_upload.sql`
14. `20260729151000_stage17_vacancies_domain.sql`
15. `20260729151050_stage17_vacancies_p1_hardening.sql`
16. `20260729152000_stage18_reviews_points_moderation.sql`
17. `20260729152050_stage18_reviews_points_p1_hardening.sql`
18. `20260729152060_stage18_reviews_points_p1_round3.sql`
19. `20260729152070_stage18_reviews_points_p1_round4.sql`
20. `20260729153000_stage19_import_studio_foundation.sql`
21. `20260729153050_stage19_import_studio_p1_hardening.sql`
22. `20260729154000_stage19_import_studio_completion.sql`

Stage 20–21: docs only.

## 4. Edge Functions deploy scope

| Function | Action | `verify_jwt` | Notes |
|---|---|---|---|
| `content-media` | **deploy new** | `false` (intentional; JWT checked in handler) | user JWT for upload/download; cleanup via secret/service_role env |
| `subject-media` | **deploy new** | `false` (intentional) | same pattern |
| `vacancy-media` | **deploy new** | `false` (intentional) | same pattern |
| `news-media` / push / cleanup-chat | **no redeploy** | — | unchanged vs origin |

Secrets required at deploy: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, cleanup dispatch secret where used.  
Smoke plan: unauth → 401; no mass notifications.

`deno check --no-config` on all three: **PASS**.

## 5. Test / build gates

| Gate | Result |
|---|---|
| `admin_console` full suite | **157/157 PASS** (news image tests updated for Published/Drafts tabs) |
| `student_ui` | **68/68 PASS** |
| Main `home_news_cache*` | **PASS** after user-scoped key fix |
| Main Stage 13.10/13.11 composer tests | **FAIL on origin baseline too** (same 3 failures on `/Users/annasuvorova/student_platform`) — not a Content Platform regression |
| Android debug APK | **PASS** |
| iOS simulator debug | **PASS** |
| Admin Web release | **PASS** (prior audit) |
| Root `flutter analyze` | package `admin_import_mapping` needs `dart pub get` in-package; in-package analyze clean |

## 6. Disposable local migration rehearsal (P1.4)

Local Docker DB `supabase_db_student_platform` (live-shaped Stage 13 schema):

* Backfilled missing predecessor `subject_offering_student_profiles` (present on remote, absent locally).
* Applied all **22** Stage 14–19 migrations successfully.
* Security reviews: Stage 15.2 / 17 / 19 **PASS**; Stage 14 review completed without error.
* Stage 14 behavioral roleplay: **ASSERTED_SCENARIOS PASS**.
* Post-apply counts: `content_items=0`, `vacancies=0`, `import_studio_batches=0` (no demo seed).

## 7. Remote before-counts (read-only, production)

| Table | Count |
|---|---|
| news_posts | 3 |
| news_versions | 11 |
| users | 34 |
| student_enrollments | 29 |
| subject_catalog | 33 |
| subject_offerings | 60 |
| academic_terms | 4 |
| entity_reviews | 0 |
| admin_permissions | 17 |
| teams | 20 |
| messages | 261 |

## 8. Release order / auto-deploy

* No `.github/workflows` auto-deploy found in repo.
* Push of `refactor/chat-tab` does **not** auto-apply Supabase migrations or Edge Functions.
* Safe order: **DB migrations → Edge deploy → then client/admin usage**. Clients dual-read / missing-RPC fallbacks remain until backend is live.

## 9. DB backup note

Git backup tag ≠ database backup. Before production apply: confirm Supabase dashboard PITR / daily backups for `gwdanmwluhrcfxbnplwd` (project ACTIVE_HEALTHY, region eu-central-1). Apply one migration at a time; stop on first failure.

## 10. Dashboard copy fix

`DashboardScreen` subtitle is now conditional: demo → local-session warning; production → “RPC + RBAC (без service_role)”.
