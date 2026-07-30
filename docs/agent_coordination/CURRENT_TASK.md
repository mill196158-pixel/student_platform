# CURRENT_TASK

* Status: **PATH B APPLIED** — migrations + Edge deploy + controlled smoke done
* Active Stage: production integration Stages 14–21 (post-apply)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311` — Path B **APPROVE** (logical backup, no PITR)
* Remote: `gwdanmwluhrcfxbnplwd`
* Backup: `/Users/annasuvorova/student_platform_backups/pre_content_platform_20260730_133051/` (outside Git; `0700`/`0600`)

## Done

* Free logical backup verified (full restore + counts/FK); PITR/add-ons not used
* All **22** Stage 14–19 migrations applied; core counts unchanged (`users=34`, `messages=261`, `news_posts=3`, …); content/vacancies/import rows = 0
* Security reviews Stage 14–19 **PASS** on remote (Stage 18 allowlist includes pre-existing `subject_alias_review_queue`)
* Edge deployed: `content-media`, `subject-media`, `vacancy-media` (v1, `verify_jwt=false`, handler auth)
* Smoke §11 subset: unauth **401**, bad bearer **401**, anon cleanup **403** — all three functions (**9/9**)

## Residuals (not blockers)

* Full authz upload/download/cross-user + trusted cleanup smoke needs real user JWTs + cleanup secret (owner fixture session)
* No Web Admin / Mobile interactive verify in this pass
* No mass import / demo publish / push

## Next (optional)

1. Owner JWT fixture smoke for upload/download/cross-user/trusted cleanup
2. Web Admin + Mobile quick verify against live RPCs
3. Mark acceptance checklist items that are now live-backed
