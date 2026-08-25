# CURRENT_TASK

* Status: **IN PROGRESS** — Stage 19.1 multi-format academic ingestion
* Active Stage: schedule boundary after Stage 19.1 foundation rollout
* Branch: `feature/content-platform`
* Codex identity-foundation verdict: **APPROVE**
* Codex document-extraction verdict: **APPROVE**
* Codex calendar-foundation/Admin-workflow verdict: **APPROVE**
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

## Residuals (not blockers)

* Local Docker remains unavailable, but the SQL foundation was verified on
  remote PostgreSQL with rollback-only fixtures.
* No real academic import, current-term transition, or Edge deploy was
  performed.

## Next (optional)

1. Review the new Admin curriculum-document and process-calendar workflows.
2. Design schedule import validation against published calendar periods.
3. Keep curriculum/calendar apply disabled until their apply contracts receive
   a separate code + tests + Codex gate.
