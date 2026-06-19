# 00 Project Reality Check

## Correct Project

- Absolute path: `C:\student_platform`
- Flutter pubspec name: `student_platform`
- Pubspec description: `MVP в стиле Cloudmate (Flutter)`
- Git branch: `refactor/chat-tab`
- Git remote: `origin https://github.com/mill196158-pixel/student_platform.git`
- Previous wrong project: `C:\flutter_gen_ai_chat_ui`
- Files copied from wrong project: no

## Root Folders

- `lib`: yes
- `docs`: yes, existing docs found
- `supabase`: yes
- `scripts`: yes
- `.cursor/rules`: created for Stage 0 REAL

## Environment Files

Checked only file presence, not contents:

- `.env`: not found by workspace glob
- `.env.local`: not found by workspace glob
- `.env.example`: not found by workspace glob

Runtime Supabase config is read from Dart defines in `lib/src/config/supabase_config.dart`:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

No `.env` values or service role keys were printed.

## Current Git Reality

The working tree was already dirty before Stage 0 REAL. Many Flutter, platform, SQL, docs, backup, and generated files were modified/untracked/deleted before this audit. Stage 0 REAL must not revert or overwrite unrelated existing changes.

Files intentionally added by this Stage 0 work are limited to:

- `.cursor/rules/academic-mvp-docs.mdc`
- `AGENTS.md`
- `docs/stage0_real/*`
- `docs/_snapshots/*`
- `scripts/collect_project_snapshot.ps1`

## Supabase Project

- Local project ref: `gwdanmwluhrcfxbnplwd`
- MCP project name: `mill196158@gmail.com's Project`
- MCP project status: `ACTIVE_HEALTHY`
- Region: `eu-central-1`
- Postgres: `17.4.1.074`

Live DB was checked read-only through Supabase MCP after authentication.
