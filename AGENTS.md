# Agent rules for Student Platform

Correct project: `C:\student_platform`.

Do not use `C:\flutter_gen_ai_chat_ui`.

Existing docs are in `docs/`.

Stage 0 REAL audit docs must go into `docs/stage0_real/`.

Before Academic MVP work:

1. Read existing docs.

2. Read Stage 0 REAL audit docs.

3. Do not overwrite existing docs unless explicitly requested.

4. Do not change Flutter code during Stage 0 REAL.

5. Do not change Supabase during Stage 0 REAL.

6. Do not expose `.env` or service role keys.

7. Use `UNKNOWN_DB` if live DB is not confirmed.

## Agent coordination

* Cursor is the lead executor.
* `codex-reviewer` is an independent architect and reviewer (OpenAI Codex via MCP).
* Before substantial implementation, Cursor must request a plan audit from Codex.
* After implementation, Cursor must send the final diff to Codex for review.
* Confirmed findings are fixed, then checks are re-run.
* Allowed without extra permission: local edits, tests, and local commit on a separate feature branch **after Codex APPROVE** for that substage.
* Normal GitHub push still requires explicit owner permission during Content Platform Stages 14–21 unless the owner lifts the ban.
* Forbidden without explicit user permission: remote Supabase apply, Edge Function deploy, production writes, force-push, deleting user changes, printing secrets, and real data import.
* On ambiguity, choose a reversible option and record the assumption; do not stop work.
* Do not ask intermediate questions when work can safely continue.

## Content Platform (Stages 14–21) — mandatory

Before continuing any Content Platform work in a session:

1. Read `docs/master_roadmap.md` (Stages 14–21 and current status).
2. Read `docs/agent_coordination/CURRENT_TASK.md` (active substage only).
3. Read `docs/content_platform/ACCEPTANCE_CHECKLIST.md`.
4. Also keep `docs/content_platform/CONTENT_PLATFORM_SPEC.md` in sync with decisions.

Checkbox / DONE rules:

* Do **not** mark an ACCEPTANCE_CHECKLIST item done without **code + tests + Codex review APPROVE** for that item (docs-only items need Codex APPROVE on the docs package).
* Do **not** mark a Stage/substage DONE without Codex APPROVE.
* Fix P0/P1 from Codex before asking for APPROVE again.
* Do not skip or merge checklist items into vague “готово”.

Remote / publish bans (Content Platform session default):

* Do **not** apply migrations to remote Supabase without the owner.
* Do **not** deploy Edge Functions without the owner.
* Do **not** push to GitHub without the owner.
* Do **not** force-push.
* Do **not** import real production data without the owner.
* Do **not** put `service_role` in Flutter Web / Admin Web.
