# CURRENT_TASK

* Status: **IN PROGRESS** — Stage 19.1 multi-format academic ingestion
* Active Stage: Stage 19.1b deterministic group recognition (Slice 1)
* Branch: `feature/content-platform`
* Codex identity-foundation verdict: **APPROVE**
* Codex document-extraction verdict: **APPROVE**
* Codex calendar-foundation/Admin-workflow verdict: **APPROVE**
* Codex plan-persistence verdict: **APPROVE_WITH_NOTES** (no P0/P1)
* Codex group-recognition architecture verdict: **APPROVE_WITH_NOTES**
  (no P0/P1)
* Codex group-recognition implementation verdict: **APPROVE_WITH_NOTES**
  (no P0/P1; PostgreSQL runtime pending)
* Codex unified Admin academic-workflow verdict: **APPROVE**
* Remote: `gwdanmwluhrcfxbnplwd`
* Backup: `/Users/annasuvorova/student_platform_backups/pre_content_platform_20260730_133051/` (outside Git; `0700`/`0600`)

## Done

* Free logical backup verified (full restore + counts/FK); PITR/add-ons not used
* All **22** Stage 14–19 migrations applied; core counts unchanged (`users=34`, `messages=261`, `news_posts=3`, …); content/vacancies/import rows = 0
* Security reviews Stage 14–19 **PASS** on remote (Stage 18 allowlist includes pre-existing `subject_alias_review_queue`)
* Edge deployed: `content-media`, `subject-media`, `vacancy-media` (v1, `verify_jwt=false`, handler auth)
* Smoke §11 subset: unauth **401**, bad bearer **401**, anon cleanup **403** — all three functions (**9/9**)
* Stage 19.1 identity foundation implemented locally:
  `educational_programs`, `curriculum_plans`, nullable group/legacy links,
  plan-local occurrence identity, apply-disabled dry-run and role-play.
* Real input audited: `up_08.03.01_pgs_2025.pdf` (text-layer, full-time
  bachelor PGS, admission 2025, eight semesters).
* Document extraction implemented and Codex **APPROVE**:
  * XLSX + text/scanned PDF diagnosis
  * self-hosted pinned PDFium Web runtime
  * editable metadata/row draft with page/rectangle provenance
  * coordinate parser v2 auto-fills aggregate hours/credits, semester
    occurrences and typed multiple controls while retaining one source subject
  * section boundaries and unresolved-control blockers fail closed
  * explicit aggregate occurrence/heading/exclude review
  * supplied PDF passes native + compiled Chrome smoke
* Academic-process calendar foundation and Admin workflow implemented with
  Codex **APPROVE**:
  * immutable calendar series/versions and reviewed periods
  * exact global/program/plan/group audience shape
  * nominal-semester protection for plan/program/global audiences
  * explicit overlap matrix and server-derived semester
  * image/PDF source review plus editable manual periods
  * apply-disabled dry-run; retry does not duplicate draft versions
* Image curriculum intake fails closed to `manualRequired`; Web OCR is not
  presented as successful recognition.
* Owner-authorized remote apply completed on `2026-08-25`:
  * `20260825102603_academic_ingestion_identity_foundation`
  * `20260825102845_academic_process_calendar_foundation`
* PostgreSQL runtime verification PASS on remote:
  * migration compile/apply and RLS/FORCE/grants assertions
  * plan identity isolation and both apply-disabled dry-runs
  * server-derived semester and published-period immutability
  * rollback-only fixtures left all Stage 19.1 domain counts at zero
  * legacy counts unchanged (`group_academic_profiles=2`,
    `curriculum_subjects=37`, all links remain `NULL`)

## In progress

* Plan-aware v2 persistence is implemented locally and Codex-reviewed:
  * durable expiring preview bound to the exact plan row version
  * atomic idempotent apply with stale/owner/hash/confirmation checks
  * aggregate-safe subject storage with per-semester workload and controls
  * editable nested semester, workload and assessment review in Admin Web
  * stale asynchronous preview responses are discarded
* Focused Flutter tests pass. PostgreSQL role-play is written but has not run
  because local Docker/PostgreSQL is unavailable.
* Stage 19.1b Slice 1 is implemented locally and Codex-approved:
  * separate reviewed program-code aliases and complete group-name aliases;
  * durable semantic group identity = program + admission year + parallel;
  * conservative parser reads parallel left, program code middle, course right;
  * server derives admission year from selected academic year and course;
  * durable read-only preview shows exact names, aliases, semantic duplicates,
    plan ambiguity, unknown programs and malformed names;
  * Admin Web exposes a fast group-name check; apply remains fail-closed.
* Unified Admin academic workflow UI is implemented locally and Codex-approved:
  * `/import-studio` starts with plan → group/student matching → annual
    process calendar → schedule/readiness cards;
  * plan/group/calendar cards open their specialized review panels directly,
    while all nine legacy XLSX domains remain in a separate advanced section;
  * global terms, annual process calendar and unavailable schedule validation
    are labeled as different operations;
  * duplicate decisions are local review intent only, classification-aware,
    unselected by default and reset with preview inputs;
  * student XLSX explicitly updates existing Auth users only.

## Residuals (not blockers)

* Local Docker remains unavailable, but the SQL foundation was verified on
  remote PostgreSQL with rollback-only fixtures.
* No real academic import, current-term transition, or Edge deploy was
  performed.

## Next (optional)

1. Execute the migration and rollback-only role-play only with owner
   authorization for remote Supabase.
2. Execute Stage 19.1b migration and rollback-only role-play only with owner
   authorization; focused Flutter tests and analyze already pass.
3. In a later approved slice, add persisted duplicate decisions and atomic group
   academic-profile/plan binding. Do not create Auth users, enrollments,
   offerings, group spaces, teams or chats in that apply.
