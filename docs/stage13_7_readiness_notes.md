# Stage 13.7 — technical readiness notes (no physical devices)

## Automated results (2026-07-27, local preflight cleared)

| Check | Result |
|---|---|
| `flutter analyze` (app) | exit 0; **0 errors**; ~194 infos/warnings mostly deprecated `withOpacity` (not mass-fixed) |
| `flutter test` (app) | **73 passed** |
| `flutter analyze` (admin_console) | **No issues** |
| Admin focused tests 13.3–13.6 | **11 passed** |
| `packages/admin_import_mapping` tests | **4 passed** |
| `git diff --check` | clean |
| Secrets scan | no client-embedded service_role secrets / no Admin service_role client |
| Deno Edge check | **PASS** (`cleanup-chat-files`, `generate-upload-url`, `dispatch-push-notifications`, `news-media`) |
| Local Supabase/Docker | **PASS** via `scripts/local_preflight_stage13.sh` |
| Stage13 security reviews | **PASS** (13.2–13.6) |
| Stage13 runtime role-play | **PASS** (6/6 scenarios) |

## Local validation method

Repo migration history is incomplete for empty-DB `supabase db reset`. Local preflight:

1. Parks historical migrations.
2. Starts clean Supabase Docker.
3. Applies live-shaped `supabase/local/pre_stage13_baseline.sql` (read-only remote introspection + recovered academic core). **Never apply baseline to remote.**
4. Applies dependency + pending migrations in order (admin RBAC → news → news archive → Stage 13.2–13.6).
5. Runs `supabase/checks/stage13_local_runtime_roleplay.sql` and `stage13_*_security_review.sql`.

`UNKNOWN_DB_LOCAL_VALIDATION` cleared.

## Known non-blockers (not local-DB residuals)

- Profile tab still uses legacy polling (`profile_screen.dart`) — outside chat Realtime path.
- Presence/session timers remain intentional.
- Text reviews feature-flagged off.
- Auth student create remains CLI/Edge-only.
- Owner Excel mapping still extensible (no real owner file).
- Physical Android/iPhone smoke still owner-gated.

## Codex

- After local preflight + Deno: target **READY** without `UNKNOWN_DB_LOCAL_VALIDATION`.

## Remote apply status (read-only MCP, project `gwdanmwluhrcfxbnplwd`)

Live migrations end at `20260722110804_news_posts_and_admin_rpc`. Not applied yet:

1. `20260722121908_admin_news_archive_delete.sql`
2. `20260727140000_stage13_2_group_space.sql`
3. `20260727150000_stage13_3_teachers_admin.sql`
4. `20260727160000_stage13_4_subjects_admin.sql`
5. `20260727170000_stage13_5_students_groups_terms_admin.sql`
6. `20260727180000_stage13_6_reviews_moderation.sql`
