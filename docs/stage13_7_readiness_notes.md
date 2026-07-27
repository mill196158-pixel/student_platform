# Stage 13.7 — technical readiness notes (no physical devices)

## Automated results (2026-07-27)

| Check | Result |
|---|---|
| `flutter analyze` (app) | exit 0; **0 errors**; ~194 infos/warnings mostly deprecated `withOpacity` / unused (not mass-fixed) |
| `flutter test` (app) | **73 passed** |
| `flutter analyze` (admin_console) | **No issues** |
| Admin focused tests 13.3–13.6 | **11 passed** |
| `packages/admin_import_mapping` tests | **4 passed** |
| `git diff --check` | clean |
| Secrets scan | no client-embedded service_role secrets |
| Deno Edge check | **blocked**: `deno` not installed locally |
| SQL local role-play | **UNKNOWN_DB_LOCAL_VALIDATION** (no full student_platform local DB stack) |

## Known non-blockers recorded

- Profile tab still uses legacy polling (`profile_screen.dart`) — outside chat Realtime path.
- Presence/session timers remain intentional.
- Text reviews feature-flagged off.
- Auth student create remains CLI/Edge-only.

## Codex

- First pass: **NO-GO** (missing ordered remote-apply list; subjects test rewrote fixture).
- After fix `6866357`: **READY_WITH_RESIDUALS** (Deno unavailable, UNKNOWN_DB, profile polling, remote/physical owner-gated).

## Physical / owner-gated

See `docs/release_checklist_v1.md`.

## Remote apply status (read-only MCP, project `gwdanmwluhrcfxbnplwd`)

Live migrations end at `20260722110804_news_posts_and_admin_rpc`. Not applied yet:

1. `20260722121908_admin_news_archive_delete.sql`
2. `20260727140000_stage13_2_group_space.sql`
3. `20260727150000_stage13_3_teachers_admin.sql`
4. `20260727160000_stage13_4_subjects_admin.sql`
5. `20260727170000_stage13_5_students_groups_terms_admin.sql`
6. `20260727180000_stage13_6_reviews_moderation.sql`
