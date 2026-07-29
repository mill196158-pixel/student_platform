# Content Platform — read-only audit evidence

Date: **2026-07-29**
Worktree: `/Users/annasuvorova/student_platform_content`
Branch: `feature/content-platform`
Local HEAD at docs APPROVE closeout: `9c8aba9`
Remote project (read-only): `gwdanmwluhrcfxbnplwd`
Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`

No secrets, no PII dumps, no remote writes.

## Remote objects confirmed

Present:

* `news_posts`, `news_versions`, `news_views` (+ archive/cleanup helpers)
* `entity_reviews` / Stage 13.6 review stack
* `admin_permissions` includes `content.read`, `content.write`, `content.publish`
* Academic import batch tables / `subject_student_profiles`

Absent (justify new content tables):

* `content_items*` / placements / content templates
* vacancies domain tables
* points ledger
* managed reference / profile_feed tables

News audience live: `all` | `group` (single `audience_group_id`) — multi-group/users need Stage 15.2 extension.

## App surfaces (filesystem)

| Surface | Finding |
|---|---|
| Home help | Hardcoded `_HelpCard` in home view |
| Profile feed | Hardcoded `_demoFeed` |
| Reference | Hardcoded `_helpItems` |
| Vacancies | Hardcoded `_demoJobs` |
| News | Production Admin + mobile pipeline; shared `student_ui` renderer |
| Reviews | Backend 13.6 present; mobile authoring incomplete |
| Import | CLI `scripts/import_academic_batch.js` + Admin XLSX for some domains |

## Reuse decision

* Do not overload `news_posts` for promo/reference/vacancies/profile feed.
* Reuse news security envelope: FORCE RLS, RPC-only DML, `private.require_admin_permission`, `content.*` perms, private storage + signed Edge.
* Extend news audience in place for Stage 15.2.
* Extend `entity_reviews` for Stage 18; dedicated vacancies domain for Stage 17.

## Migration patterns to copy

* `20260722110804_news_posts_and_admin_rpc.sql`
* `20260727183823_admin_news_archive_delete.sql`
* `20260721202054_admin_rbac_and_audit.sql`

Audience membership helper already exists: `private.current_user_active_group_ids()` via active `student_enrollments`.
