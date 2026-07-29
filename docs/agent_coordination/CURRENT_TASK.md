# CURRENT_TASK

* Status: **STAGE_16_3_REFERENCE** / starting after 16.2 APPROVE_WITH_NOTES + local commit
* Active Stage: **16 — Subject card / files / reference**
* Exact substage: **16.3** reference section
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Just closed

* Stage **16.2** subject images/files — Codex **APPROVE_WITH_NOTES** (no P0/P1) → local commit (this session)
* Stage **16.1** text/links/ordering — Codex **APPROVE** → `6e03828`

## Stage 16.2 residuals (non-blocking P2)

* Local/full Storage finalize + idempotent finalize not executed (no local Supabase stack)
* Edge deploy owner-gated; `config.toml` sets `verify_jwt=false` for `subject-media` (cleanup secret path)

## Next — Stage 16.3

1. Plan audit / SPEC lock if needed
2. Implement reference content (`reference_article_v1`, categories, report-error → moderation)
3. Tests + Codex until APPROVE
4. Separate local commit; continue 17→19

## Codex verdicts (local)

| Slice | Verdict | Commit |
|---|---|---|
| Docs gate | APPROVE | `d1796ac` / `9c8aba9` |
| 14A–15.3 | APPROVE | through `cebfcf5` |
| 16.1 plan | APPROVE | (SPEC lock) |
| 16.1 impl | APPROVE | `6e03828` |
| 16–19 SQL drafts | APPROVE_WITH_NOTES | `3772b4a` / `5629da9` |
| 20–21 specs | APPROVE | `e279c53` / `5f23429` |
| 16.2 plan | APPROVE | (SPEC lock) |
| 16.2 impl | **APPROVE_WITH_NOTES** | (pending this commit) |
| 16.3 | pending | — |

## Hard bans

No remote migration apply · No Edge deploy · No GitHub push · No real import · No service_role in Web · No merge into `refactor/chat-tab` · No checklist DONE without tests + Codex APPROVE

## Residuals (unchanged)

* Docker end-to-end roleplay not executed locally
* Owner residuals Stage 13: PHYSICAL OCR / push / REAL XLSX
* Unrelated dirty tree (profile-feed formatting) — exclude from stage commits
