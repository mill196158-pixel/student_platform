# CURRENT_TASK

* Status: **STAGE_16_2_SUBJECT_ASSETS** / starting after 16.1 APPROVE+commit
* Active Stage: **16 — Subject card / files / reference**
* Exact substage: **16.2** subject images/files (signed private media)
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Just closed

* Stage **16.1** text/links/ordering — Codex **APPROVE** → local commit (this session)

## Next (16.2)

* Private Storage + signed upload/download
* MIME/size whitelist, versioning, cleanup queue
* No Base64 in DB
* Wire Admin/Mobile subject card media (was deferred from 16.1)
* Draft migration exists: `20260729150600_stage16_2_subject_assets.sql`
* Security review draft: `supabase/checks/stage16_2_subject_assets_security_review.sql`

## Codex verdicts (local)

| Slice | Verdict | Commit |
|---|---|---|
| Docs gate | APPROVE | `d1796ac` / `9c8aba9` |
| 14A–15.3 | APPROVE | through `cebfcf5` |
| 16.1 plan | APPROVE | (SPEC lock) |
| 16.1 impl | APPROVE | (pending this commit) |
| 16–19 SQL drafts | APPROVE_WITH_NOTES | `3772b4a` / `5629da9` |
| 20–21 specs | APPROVE | `e279c53` / `5f23429` |

## Hard bans

No remote migration apply · No Edge deploy · No GitHub push · No real import · No service_role in Web · No merge into `refactor/chat-tab`

## Residuals

* Docker end-to-end roleplay not executed locally (SQL checks authored)
* CRLF normalize before/with commit where needed
* Owner residuals Stage 13: PHYSICAL OCR / push / REAL XLSX
