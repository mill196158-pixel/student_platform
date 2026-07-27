# Stage 13.7 — technical readiness notes

## Status split (2026-07-27)

| Layer | Status |
|---|---|
| Schema + RPC + RLS (13.2–13.6 + news archive + organizer admin) | **TECHNICALLY DONE** (applied on remote `gwdanmwluhrcfxbnplwd`) |
| Edge Functions (`news-media`, `generate-upload-url`, `cleanup-chat-files`, `dispatch-push-notifications`) | **TECHNICALLY DONE** (redeployed; unauth → 401) |
| Flutter/Admin automated tests | **TECHNICALLY DONE** |
| Real owner Excel import to production | **REAL XLSX REQUIRED** (not run; fixtures not imported) |
| Android / iPhone / push / poor network | **PHYSICAL SMOKE REQUIRED** |

## Automated results

| Check | Result |
|---|---|
| `flutter analyze` (app) | exit 0; **0 errors**; 194 infos/warnings (mostly deprecated `withOpacity`, not mass-fixed) |
| Stage 13 app tests (group-space/info/profile) | **31 passed** |
| `flutter analyze` (admin academic/auth) | **No issues** |
| Admin Stage 13.3–13.6 focused tests | **18 passed** |
| `git diff --check` | clean |
| Secrets scan | no client-embedded `service_role` |
| Deno Edge check | **PASS** (4 functions) |
| Remote security reviews (assertive) | **PASS** news + 13.2–13.6 |
| Remote feature flags | `reviews.structured_enabled=true`, `reviews.text_enabled=false` |

## Remote migrations applied (project `gwdanmwluhrcfxbnplwd`)

| Remote version | Name | Post-check |
|---|---|---|
| `20260727183823` | `admin_news_archive_delete` | PASS |
| `20260727184049` | `stage13_2_group_space` | PASS |
| `20260727184156` | `stage13_3_teachers_admin` | PASS |
| `20260727184238` | `stage13_4_subjects_admin` | PASS |
| `20260727184423` | `stage13_5_students_groups_terms_admin` | PASS |
| `20260727184457` | `stage13_6_reviews_moderation` | PASS |
| `20260727184511` | `stage13_2_admin_group_organizer` | PASS |

Local filenames were `git mv`-aligned to these remote timestamps (SQL unchanged).

Organizer admin migration applied **after** 13.5 (depends on `stage13_5_can` / `admin_ensure_group_space_for_group`).

## Edge deploy

| Function | Version | verify_jwt | Unauth smoke |
|---|---|---|---|
| `news-media` | 2 | true | 401 |
| `generate-upload-url` | 7 | true | 401 |
| `cleanup-chat-files` | 4 | false (custom bearer) | 401 missing bearer |
| `dispatch-push-notifications` | 4 | false (custom bearer) | 401 missing bearer |

`teacher-media` remains deferred (not deployed).

## Intentionally not changed on production

- No fixture Excel imports
- No synthetic teachers/students/subjects/reviews/groups left in DB
- No mass push sends
- `users.role` starosta backfill was 0 rows
- No entity_reviews rows created

## Remaining owner work

1. **REAL XLSX REQUIRED** — import teachers/subjects/students with real files via Admin dry-run → apply.
2. **PHYSICAL SMOKE REQUIRED** — Android/iPhone checklist in `docs/release_checklist_v1.md` (chat, group space, push, offline).
3. Assign first organizers via Admin: **Студенты → группа → Организаторы пространства группы** (or rely on active subject-team starosta).
