# Production integration preflight — Stages 14–21

Date: **2026-07-30** (refreshed after Codex CHANGES_REQUESTED)  
Content worktree: `/Users/annasuvorova/student_platform_content` @ `feature/content-platform`  
Main worktree: `/Users/annasuvorova/student_platform` @ `refactor/chat-tab`  
Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`  
Remote project: `gwdanmwluhrcfxbnplwd`

## 1. Git state

| Worktree | Branch | Status | Notes |
|---|---|---|---|
| content | `feature/content-platform` | pushed to origin | ahead of `origin/refactor/chat-tab` (~29 commits); behind **0** |
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
* Security reviews **PASS** after check alignment with thin public wrappers:
  * Stage 14 / 15.2 / 16.1 / 16.2 / 16.3 (corrections + hardening) / 17 / 18 / 19
  * Stage 16.2 / 18 checks previously looked for guard strings on public `admin_*` stubs; guards live in `private.register_subject_asset` / `private.review_moderate_apply` (and audit via that helper). Checks updated accordingly.
* Stage 14 behavioral roleplay: **ASSERTED_SCENARIOS PASS**.
* Stage 16.1 / 16.2 / 16.3 roleplays: **OK** after seeding disposable logins (`admin_roleplay` / `student_roleplay` / `student_other_roleplay` on existing Stage 13 fixtures) and setting `request.jwt.claims` JSON for `service_role` paths (`auth.jwt()` does not read `claim.role` alone).
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

## 9. DB backup evidence (free logical dump — no PITR / no paid add-ons)

Owner decision: **do not enable PITR or any paid Supabase add-ons**. Path B recoverability gate = verified manual logical backup.

| Evidence | Status |
|---|---|
| Git backup tag | `backup/pre-content-platform-20260730` @ `c31f572` |
| Git backup branch | `backup/refactor-chat-tab-pre-content-20260730` (pushed) |
| Project status (MCP `get_project`) | **ACTIVE_HEALTHY**, region `eu-central-1`, Postgres 17.4.1 |
| Logical backup dir (outside Git/worktree) | `/Users/annasuvorova/student_platform_backups/pre_content_platform_20260730_133051/` |
| CLI | Supabase CLI **2.109.1** — `supabase db dump` (`--data-only`, `--role-only`, default schema) |
| `01_schema.sql` | 820 887 bytes · SHA-256 `b9bd58147d7c5c31ca9501850c10caabc71f1f1f0b7ad8b18fec247f6d4d4d31` |
| `02_data.sql` | 1 871 113 bytes · SHA-256 `22c8759a133266a471f5d1cbee1c261009407a7bfaf09b5157767cebd2ec9234` · 128 `COPY` · schemas `auth`/`public`/`storage` · dump complete marker present |
| `03_roles.sql` | 297 bytes · SHA-256 `25873cec56a2cc6514e204f420231777f85c03da818caa7090cdcdfa89776ecd` · managed-role timeout ALTERs only (expected) |
| Structural verify | Disposable local `psql -f 01_schema.sql` → **rc=0**, **0 ERROR lines**, 1620 successish statements; schema has 99 tables / 331 functions |
| Restore runbook | `RESTORE_RUNBOOK.md` in backup dir (circular FK note for data load) |
| Git status | backup path **not** present in either worktree `git status` |

Secrets (DB password, tokens, connection strings, service_role) are **not** stored in the backup folder or this doc. Apply one migration at a time; stop on first failure.

## 10. Dashboard copy fix

`DashboardScreen` subtitle is now conditional: demo → local-session warning; production → “RPC + RBAC (без service_role)”.

## 11. Edge smoke runbook (post-deploy, locked)

Target: `content-media`, `subject-media`, `vacancy-media` only. No mass push, no real XLSX, no demo publish.

Base URL: `https://gwdanmwluhrcfxbnplwd.supabase.co/functions/v1/<fn>`

| # | Case | How | Expected |
|---|---|---|---|
| 1 | Unauth | `POST` with no `Authorization` / empty body `{ "action": "createUploadIntent", ... }` | **401** |
| 2 | Authz upload | Valid student/admin JWT + allowed MIME/size for createUploadIntent → finalize from Storage metadata | **200**; asset row owned by actor |
| 3 | Authz download | Owner (or authorized reader) JWT + `authorize*Download` path | **200** signed URL; **no** raw storage path in client payload |
| 4 | Cross-user deny | User B JWT on User A asset id | **403** / not authorized |
| 5 | Ordinary-user cleanup deny | User JWT `action=processCleanup` | **401/403** (cleanup requires `CLEANUP_DISPATCH_SECRET` or service_role bearer) |
| 6 | Trusted cleanup success | Bearer = cleanup secret (or service_role) + leased claim | **200**; claim processed |
| 7 | Fixture cleanup | Delete any smoke-created storage objects + DB asset/intent rows | counts unchanged vs before-smoke |

Stop deploy promotion on any unexpected 2xx for cases 1/4/5.
