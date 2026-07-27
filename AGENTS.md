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
* Allowed without extra permission: local edits, tests, commit, and normal push — only on a separate feature branch.
* Forbidden without explicit user permission: remote Supabase apply, Edge Function deploy, production writes, force-push, deleting user changes, and printing secrets.
* On ambiguity, choose a reversible option and record the assumption; do not stop work.
* Do not ask intermediate questions when work can safely continue.
