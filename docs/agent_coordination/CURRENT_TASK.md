# CURRENT_TASK

* Status: **IN PROGRESS** — Stage 19.1 multi-format academic ingestion
* Active Stage: Stage 19.1b deterministic group recognition (Slice 2)
* Branch: `feature/content-platform`
* Codex identity-foundation verdict: **APPROVE**
* Codex document-extraction verdict: **APPROVE**
* Codex calendar-foundation/Admin-workflow verdict: **APPROVE**
* Codex plan-persistence verdict: **APPROVE_WITH_NOTES** (no P0/P1)
* Codex group-recognition architecture verdict: **APPROVE_WITH_NOTES**
  (no P0/P1)
* Codex group-recognition implementation verdict: **APPROVE_WITH_NOTES**
  (no P0/P1)
* Codex group-recognition Slice 2 verdict: **APPROVE**
  (no P0/P1; remote PostgreSQL runtime PASS)
* Codex unified Admin academic-workflow verdict: **APPROVE**
* Remote: `gwdanmwluhrcfxbnplwd`
* Backup: `/Users/annasuvorova/student_platform_backups/pre_content_platform_20260730_133051/` (outside Git; `0700`/`0600`)

## Done

* Free logical backup verified (full restore + counts/FK); PITR/add-ons not used
* All **22** Stage 14–19 migrations applied; core counts unchanged (`users=34`, `messages=261`, `news_posts=3`, …); content/vacancies/import rows = 0
* Security reviews Stage 14–19 **PASS** on remote (Stage 18 allowlist includes pre-existing `subject_alias_review_queue`)
* Edge deployed: `content-media`, `subject-media`, `vacancy-media` (v1, `verify_jwt=false`, handler auth)
* Smoke §11 subset: unauth **401**, bad bearer **401**, anon cleanup **403** — all three functions (**9/9**)
* Complete `refactor/chat-tab` Visual Content Studio is integrated with the
  Stage 19.1 academic branch and received Codex **APPROVE**:
  * nontechnical list + phone preview + properties workflow is restored;
  * Content, Academic and Import Studio routes remain visible under existing
    RBAC;
  * full Admin tests and both Admin/student Web release builds pass.
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
  * `20260825202814_group_identity_recognition_foundation`
  * `20260825202823_stage19_1b_group_recognition_apply`
  * `20260825202929_academic_plan_import_persistence`
  * `20260825203114_group_recognition_refresh_ambiguity_hotfix`
* PostgreSQL runtime verification PASS on remote:
  * migration compile/apply and RLS/FORCE/grants assertions
  * plan identity isolation and both apply-disabled dry-runs
  * server-derived semester and published-period immutability
  * rollback-only fixtures left all Stage 19.1 domain counts at zero
  * legacy counts unchanged (`group_academic_profiles=2`,
    `curriculum_subjects=37`, all links remain `NULL`)
  * plan persistence role-play passed **20/20**
  * group decision/apply role-play passed **23/23**

## In progress

* Plan-aware v2 persistence is implemented, remote-applied and Codex-reviewed:
  * durable expiring preview bound to the exact plan row version
  * atomic idempotent apply with stale/owner/hash/confirmation checks
  * aggregate-safe subject storage with per-semester workload and controls
  * editable nested semester, workload and assessment review in Admin Web
  * stale asynchronous preview responses are discarded
* Focused Flutter tests pass; the rollback-only PostgreSQL role-play passed
  remotely without preserving fixtures.
* Stage 19.1b Slice 1 is remote-applied and Codex-approved:
  * separate reviewed program-code aliases and complete group-name aliases;
  * durable semantic group identity = program + admission year + parallel;
  * conservative parser reads parallel left, program code middle, course right;
  * server derives admission year from selected academic year and course;
  * durable read-only preview shows exact names, aliases, semantic duplicates,
    plan ambiguity, unknown programs and malformed names;
  * Admin Web exposes a fast group-name check; apply remains fail-closed.
* Stage 19.1b Slice 2 is remote-applied and Codex **APPROVE**:
  * durable zero-or-one decisions are stored only for actionable rows;
  * preview v2 stores human candidate labels plus alias/program/identity/
    profile/plan/max-semester drift snapshots;
  * owner-scoped `groups.write` decision replacement is atomic and
    revision/hash bound;
  * apply is bound to preview row version, payload hash, decision revision/hash
    and an exact confirmation token;
  * reused groups follow the insert/retain/bind-only compatibility matrix;
    existing plans are never replaced;
  * new groups are inserted directly, without `admin_upsert_group`, so no
    accounts, enrollments, offerings, spaces, teams or chats are created;
  * immutable row results support exact idempotent replay;
  * Admin Web saves durable decisions, uses candidate-specific group/plan
    selectors, confirms the exact revision and shows a plain-language result;
  * local demo apply remains disabled;
  * changed-file analyze and all seven focused academic/group test files pass
    (**28 tests**); `git diff --check` passes.
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

* Local Docker remains unavailable; owner-authorized remote PostgreSQL
  migration and rollback-only verification replaced the local runtime gate.
* No real academic import, current-term transition, or Edge deploy was
  performed.

## Next (optional)

1. Keep real group/student import separately
   owner-gated. Do not create Auth users, enrollments, offerings, group spaces,
   teams or chats through group recognition.
