# Stages 16–19 — SQL foundation notes (LOCAL ONLY)

Status: **FOUNDATION DRAFT — reworked after Codex REJECT (round 1), pending
re-APPROVE.**

Not DONE. Not applied anywhere. Nothing in `ACCEPTANCE_CHECKLIST.md` may be
marked `[x]` from this package until Codex re-reviews the rework and APPROVEs.

These notes cover only the SQL foundation. Admin Web and Flutter work for these
stages is separate.

## Round-1 rework summary

Codex rejected the first cut with P1 findings. What changed:

| Stage | P1 | Resolution |
| --- | --- | --- |
| 16 | Two competing migrations overlapped on the subject card, and the broad one duplicated `hours_total` / `credits` onto the profile tables | The broad `20260729150000` file was **deleted** and replaced by two additive files: 16.2 assets and 16.3 corrections. Neither touches a profile column. Load stays in `curriculum_subjects`, reached through the offering. |
| 17 | `private.vacancy_expire_due()` changed lifecycle with no snapshot and no trail | Rewritten row-by-row and bounded (`p_limit`): each vacancy gets a version snapshot plus an `auto_expire` moderation + audit row. The old zero-argument overload is dropped so cron cannot call the audit-less one. |
| 17 | Draft creation recorded `take_in_moderation` while the state was `draft` | `create_draft` and `submit` were added to the trail vocabulary; drafts now record `create_draft`, submissions record `submit`. |
| 17 | `admin_delete_vacancy_asset` could break a published card | It now refuses with `unpublish_vacancy_before_deleting_asset` while the vacancy is published. |
| 18 | An approval was recorded as `restore` | `approve`, `reject` and `remove_violation` were added to `review_moderation_actions.action`; an approval is recorded verbatim. |
| 18 | The legacy `admin_moderate_review` could bypass points compensation | Both entry points now delegate to `private.review_moderate_apply`; neither writes review state itself. Legacy `hide` → `reject`, legacy `restore` → `restore`. |
| 18 | Auto-approved legacy reviews never got their `+1` | Points moved onto an `AFTER INSERT OR UPDATE` trigger (`trg_entity_reviews_points_sync`), so an auto-approved insert is credited too, plus an idempotent `public.admin_backfill_review_points(p_limit)` for rows that predate this migration. |
| 18 | Uniqueness on `(review_id, reason_code)` made a re-credit after compensation impossible | The ledger is now **cycle**-based: `cycle_number` column, uniqueness on `(review_id, reason_code, cycle_number)`. Cycle 1 is the first `+1`, its compensating `-1` shares cycle 1, a later re-credit opens cycle 2. |
| 18 | rejected → resubmit → pending was incomplete | The author edit path returns the review to `pending`, clears the stale rejection reason, and the moderation gate also re-opens an edited `approved` **or** `rejected` review. A review removed as a violation stays terminal. |
| 19 | `batch_key` uniqueness was global | Uniqueness is now `(created_by, domain, batch_key)`, `created_by` is `NOT NULL ON DELETE RESTRICT`, and every batch-scoped RPC calls `private.import_studio_assert_owner`. |
| 19 | `academic.read` acted as a generic cross-domain PII read | Reading staged payloads now requires the **domain's own** permission. `academic.read` opens only the payload-free hub catalogue (`admin_import_studio_list_domains`). |
| 19 | The domain list implied more capability than exists | `private.import_studio_domain_state` is the single honest statement: `apply` / `validate_only` / `not_implemented`. `offerings`, `teacher_links` and `enrollments` are declared but every call raises `not_implemented_domain_*`. |
| 19 | No rollback story | `public.admin_import_studio_rollback_batch(p_batch_id, p_confirm_batch_key)` exists as an explicit refusal: it requires ownership, an applied batch and a batch-key confirmation, audits the attempt, and then refuses because `rollback_safe` is never set in this foundation. |

## Files

Migrations (new; none of the already-applied files were edited):

| File | Scope |
| --- | --- |
| `supabase/migrations/20260729150500_stage16_1_subject_card_foundation.sql` | Subject **card**: columns, `section_order`, `row_version`, `get_subject_card`, `admin_upsert_subject_card`, card write lockdown |
| `supabase/migrations/20260729150600_stage16_2_subject_assets.sql` | Subject files: `subject_assets` (typed XOR owner), `subject_media_cleanup_queue`, private `subject-media` bucket |
| `supabase/migrations/20260729150700_stage16_3_reference_corrections.sql` | `content_corrections` — «Сообщить об ошибке» on Stage 14 content |
| `supabase/migrations/20260729151000_stage17_vacancies_domain.sql` | Vacancies domain, status machine, audience, reports, assets |
| `supabase/migrations/20260729152000_stage18_reviews_points_moderation.sql` | `entity_reviews` moderation, cycle-based points ledger, unified queue |
| `supabase/migrations/20260729153000_stage19_import_studio_foundation.sql` | Import Studio batches/rows, dry run, diff, apply, rollback refusal |

Deleted in this rework (was never applied anywhere):
`supabase/migrations/20260729150000_stage16_subject_content_and_reference.sql`
and its check `supabase/checks/stage16_subject_content_security_review.sql`.

Static security reviews:

- `supabase/checks/stage16_1_subject_card_security_review.sql`
- `supabase/checks/stage16_2_subject_assets_security_review.sql`
- `supabase/checks/stage16_3_reference_corrections_security_review.sql`
- `supabase/checks/stage17_vacancies_security_review.sql`
- `supabase/checks/stage18_reviews_points_security_review.sql`
- `supabase/checks/stage19_import_studio_security_review.sql`

Each check file ends with a hard-gate `DO` block, so it can be run with
`ON_ERROR_STOP=1` as a pass/fail step instead of being eyeballed. The blocks are
read-only. Stages 17–19 additionally carry a `P1 REWORK ASSERTIONS` section with
its own gate, so a later refactor cannot silently reopen a Codex finding.

Behavioral role-play:

- `supabase/checks/stage16_19_p1_roleplay.sql` — one disposable transaction
  (`begin` … `rollback`) covering the P1 behaviours end to end: asset-chain
  IDOR, published-card asset safety, report IDOR and reporter anonymity, cron
  expiry snapshot/audit, `create_draft` vs `take_in_moderation`, contact
  privacy, `approve` vs `restore`, legacy-path compensation, credit → debit →
  re-credit cycles, rejected → resubmit → pending, backfill idempotency,
  per-operator batch ownership, `not_implemented` refusal, rollback refusal.
  Missing fixtures produce explicit `SKIP` rows, never a silent `PASS`.

## Permission matrix

Existing live permission codes only; no new codes were invented. Moderation
writes accept `moderation.action` **or** `moderation.write`, because live RBAC
seeds both for the same capability.

| Area | Read | Write / act |
| --- | --- | --- |
| Subject card (catalog + offering) | `content.read` or `subjects.write` | `subjects.write` |
| Subject files | `content.read` or `subjects.write` | `subjects.write` |
| Subject card publish | — | `content.publish` |
| Content corrections queue | `moderation.read` | `moderation.action` / `moderation.write` |
| Vacancies (admin list/get) | `content.read` | `content.write` |
| Vacancy moderation | `moderation.read` | `moderation.action` / `moderation.write` |
| Vacancy publish / lifecycle | — | `content.publish` |
| Vacancy reports | `moderation.read` | `moderation.action` / `moderation.write` |
| Reviews moderation | `moderation.read` | `moderation.action` / `moderation.write` |
| Review points backfill | — | `moderation.action` / `moderation.write` |
| Student points (admin view) | `moderation.read` or `students.read` | ledger is trigger/RPC-written only |
| Unified moderation queue | `moderation.read` | dispatch re-checks the per-domain permission |
| Import Studio — hub catalogue (no payloads) | `academic.read` or any domain permission | — |
| Import Studio — teachers | `teachers.write` | `teachers.write` |
| Import Studio — subjects | `subjects.write` | `subjects.write` |
| Import Studio — students | `students.write` | `students.write` |
| Import Studio — groups | `groups.write` | validate-only, apply blocked |
| Import Studio — curriculum | `subjects.write` | validate-only, apply blocked |
| Import Studio — terms | `terms.manage` | validate-only, apply blocked |
| Import Studio — offerings / teacher_links / enrollments | not implemented | not implemented |

Reading a batch's **staged rows** always requires that domain's own permission,
never `academic.read`: staged rows carry logins, names and e-mails.

Student-facing RPCs (`get_subject_card`, `get_subject_card_assets`,
`get_my_vacancies`, `get_vacancy_contacts`, `submit_vacancy`, `report_vacancy`,
`submit_content_correction`, `submit_my_entity_review`,
`get_my_points_summary`) require an authenticated `auth.uid()` and enforce
audience/enrollment scoping inside the function body.

Posture for every new table: RLS enabled **and** forced, no `anon` /
`authenticated` table grants, no RLS policies, DML for `service_role` only.
All client access goes through `SECURITY DEFINER` RPCs with `search_path = ''`.
No `service_role` key is needed in Admin Web — every Import Studio RPC is
callable by `authenticated` and does its own RBAC check.

## Decisions worth flagging in review

1. **One subject-card model, one load source.** The card lives only in
   `20260729150500`. `hours_total` / `credits` are **not** stored on
   `subject_student_profiles` or `subject_offering_student_profiles`; the single
   source of truth is `curriculum_subjects`, reached through the offering, and
   it is surfaced by `get_subject_card` only. Stages 16.2 and 16.3 are additive
   and touch no profile column. Card writes go through the RPCs: client DML on
   the card tables is revoked.
2. **Assets are not polymorphic.** `subject_assets` uses `subject_catalog_id`
   XOR `subject_offering_id` (constraint `subject_assets_owner_xor`);
   `vacancy_assets` uses a plain `vacancy_id` FK. New private bucket
   `subject-media` (20 MB, image/pdf whitelist). Registering a new *version*
   must supersede a file of the same owner, otherwise `asset_foreign_owner`.
3. **Deleting a file cannot break a live card.** Subject and vacancy deletions
   refuse while the owning card / vacancy is published; the supported path is
   supersede, or unpublish first. Deletion enqueues the storage object before
   the row disappears, so a private object is never orphaned.
4. **Reference reuses Stage 14.** `content_corrections.content_item_id` is an FK
   to `content_items`; no parallel reference system was created. Submitting
   requires the item to be *deliverable* to the caller, one open report per
   `(item, reporter)` is enforced by a partial unique index, and the moderator
   queue never returns reporter identity.
5. **Reviews are extended, not replaced.** `entity_reviews` gained
   `moderation_status` / `moderation_reason` / `moderated_by` / `moderated_at`.
   Publish-after-approve is behind the `reviews.moderation_required` feature
   flag, default **off**, so Stage 13.6 behaviour is unchanged until the owner
   flips it. A trigger keeps a pending review out of the public read paths.
6. **Points are cycle-based and trigger-owned.** `private.review_points_sync_one`
   is the only writer, called by `trg_entity_reviews_points_sync`, so no
   moderation path — Stage 18, legacy Stage 13.6 or a future one — can credit
   without compensating or compensate without a trail. History is never
   deleted: a removal writes a compensating `-1` in the same cycle, and a later
   restoration opens the next cycle.
7. **Vacancy contacts are gated.** `get_my_vacancies` returns only a
   `has_contacts` boolean; raw contacts come from `get_vacancy_contacts`, which
   re-checks published + audience visibility.
8. **Import Studio is honest about being partial.** The domain matrix is one
   function, the hub derives `can_dry_run` / `can_apply` from it, and an
   unimplemented domain raises `not_implemented_domain_*` from both gates *and*
   from the row validator (defence in depth) instead of returning an empty
   result that looks like success.
9. **Import Studio term safety is two-layered.** The dry-run validator flags
   `current_term_flip_forbidden` / `autumn_2026_forbidden`, and apply also runs a
   before/after fingerprint tripwire. Autumn 2026 creation and current-term
   flips are both refused.
10. **`private.require_any_admin_permission` is duplicated** in the Stage 16.2,
    16.3, 17, 18 and 19 migrations so each file stays self-contained and
    re-appliable. The definitions are byte-identical, so apply order does not
    matter.

## Local verification performed

The round-1 package was verified on a throwaway Docker Postgres (never a remote
project): all migrations applied twice cleanly, the static gates passed, and a
60-assertion runtime smoke test passed.

**That verification predates this rework.** For the reworked files only the
following has been done so far:

- Every touched migration and check file parses (no syntax errors) on a
  throwaway Postgres 16 container; the plpgsql bodies are syntax-validated at
  `CREATE` time.
- The static hard gates execute and raise correctly rather than silently
  passing.
- `git diff --check` is clean for the touched files (no trailing whitespace, no
  CRLF).

A **full re-apply plus re-run of every gate and the new role-play is still
outstanding** and is listed as a blocker below.

19 pre-existing migrations from June/July (chat, friends, presence, push, and
`*_draft` files) still fail to apply from empty on this harness. That is
unrelated to Stages 16–19 and was already the case before this work.

## Known blockers / follow-ups

1. **Not applied, not re-reviewed.** Remote apply, Edge Function deploy, GitHub
   push and commit were all deliberately skipped per the session bans. Codex
   re-APPROVE of this rework is required before any checklist item flips to
   `[x]`.
2. **Re-run the harness.** The reworked migrations have not been applied
   end-to-end on the Docker harness yet, so the static gates and
   `stage16_19_p1_roleplay.sql` have not been executed against a real schema.
   This is the top follow-up before APPROVE is requested.
3. **`supabase/checks/stage14_managed_content_security_review.sql` has a false
   alarm.** Its checks 8 and 9 test `'search_path=' = any(p.proconfig)`, but
   Postgres stores `set search_path = ''` as `search_path=""` (with literal
   quotes). Those two queries therefore report *every* correctly-hardened
   function as failing. The Stage 16–19 files use a quote-stripping predicate
   instead. Stage 14's file was left untouched because it already carries a
   Codex APPROVE; it should be corrected separately.
4. **Signed-URL Edge Function is not written.** Subject and vacancy assets are
   registered and validated in SQL, and students receive descriptors only, so a
   `service_role` Edge Function still has to mint the signed URLs.
5. **Expiry needs a schedule.** `private.vacancy_expire_due(p_limit)` now
   snapshots and audits, but nothing calls it; a cron entry is required for
   `published` → `expired`. Note the zero-argument overload was dropped, so any
   future cron entry must call the `p_limit` version (the default makes
   `private.vacancy_expire_due()` still resolve).
6. **Cleanup queues need a worker.** `subject_media_cleanup_queue` and
   `vacancy_media_cleanup_queue` accumulate rows that no job drains yet.
7. **Import Studio apply is delegated, not reimplemented.** `teachers`,
   `subjects` and `students` route into the existing Stage 13.3–13.5 import
   RPCs. `groups`, `curriculum` and `terms` are validate-only on purpose and
   need an owner decision before they can apply. `offerings`, `teacher_links`
   and `enrollments` are declared but not implemented.
8. **Rollback is a refusal, not an undo.** No domain sets `rollback_safe`, so
   `admin_import_studio_rollback_batch` always refuses. A real undo needs a
   per-domain reversal plan, and domains that create auth users are inherently
   irreversible — that decision belongs to the owner.
9. **Points backfill has not been run.** `admin_backfill_review_points` is
   idempotent and safe to re-run, but it is an explicit operator action; it is
   not triggered by the migration.
10. **`reviews.moderation_required` is off.** Turning it on changes student
    behaviour: clients must call `submit_my_entity_review`, and the Admin
    unified queue has to be live first, or reviews will pile up unmoderated.
11. **Timestamp collision was resolved by a parallel agent.** Stage 16.1's
    subject-card migration originally shared the `20260729150000` prefix and now
    sits at `20260729150500`. There is no remaining duplicate prefix, and the
    three Stage 16 files define no overlapping objects.
