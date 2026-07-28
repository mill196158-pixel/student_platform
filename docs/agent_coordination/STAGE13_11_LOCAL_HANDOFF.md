# Handoff: finish Stage 13.11 (Codex APPROVE → remote apply → push)

Repo: student_platform
Branch: refactor/chat-tab (already pushed)
HEAD: 3784abff80f951508abf042059280261534be738
Codex thread: 019fa373-81f2-7962-a8c9-81d86cb62311
Remote project: gwdanmwluhrcfxbnplwd
PR: https://github.com/mill196158-pixel/student_platform/pull/1

## Already done on branch
- Migration `supabase/migrations/20260728105753_stage13_11_membership_capabilities_ux.sql` (NOT applied remotely)
- Membership create vs organizer moderate split
- Silent capabilities cache (no «Проверяем права»)
- Collection/topic form redesign; schedule unify; Lottie empty states
- Tests 13.9–13.11 PASS; Web+Admin Web+Android debug APK built
- Checks: `supabase/checks/stage13_11_membership_capabilities_{roleplay,security_review}.sql`

## Do now (local Agent — MCP already logged in)
1. Codex-reply to thread 019fa373-81f2-7962-a8c9-81d86cb62311 with full diff 235bc23..HEAD and per-item checklist (14 blocks). Fix all P0/P1 until APPROVE on each.
2. Read-only live audit login `24002820` (user_id, memberships, capabilities per chat). No secrets in report.
3. Before counts → apply ONLY Stage 13.11 migration → security_review + roleplay BEGIN…ROLLBACK → after counts; cleanup test data; no mass push; no Edge redeploy unless Edge changed.
4. Align migration timestamp if remote renames; mark Stage 13.11 DONE in docs/master_roadmap.md + CURRENT_TASK.md; commit; normal push origin/refactor/chat-tab; update PR.
5. Final 17-point report.

Constraints: do not edit applied migrations; no service_role in Flutter; no force-push.
