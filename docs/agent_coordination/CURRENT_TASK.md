# CURRENT_TASK

* Status: **CONTENT_PLATFORM_LOCAL_CHAIN_PARKED** / awaiting owner apply/deploy/push
* Branch: `feature/content-platform` (ahead of `origin/refactor/chat-tab`; also behind 1)
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Codex verdicts (local)

| Slice | Verdict | Commit |
|---|---|---|
| Docs gate | APPROVE | `d1796ac` / `9c8aba9` |
| 14A SQL | APPROVE | `2588581` |
| 14B models | APPROVE | `691f43e` / `74c779d` |
| 15.1 Home promo | APPROVE | `183efc8` |
| 15.2 News audience | APPROVE | `001e1f0` |
| 15.3 Profile feed | APPROVE | `cebfcf5` |
| 16 SQL foundation | APPROVE_WITH_NOTES (FOUNDATION DRAFT) | `3772b4a` |
| 17 Vacancies SQL | APPROVE_WITH_NOTES (FOUNDATION DRAFT) | `5629da9` |
| 18 Reviews/points SQL | APPROVE_WITH_NOTES (FOUNDATION DRAFT) | `5629da9` |
| 19 Import Studio SQL | APPROVE_WITH_NOTES (FOUNDATION DRAFT) | `3772b4a` |
| 20 AI spec | APPROVE | `e279c53` |
| 21 RF roadmap | APPROVE | `e279c53` |

## Residuals / blockers

* Stage 16.1 **product UI** (Admin subject card editor + mobile wiring) — uncommitted WIP; compile/tests not green → **BLOCKED** for DONE
* Full Docker chain apply + behavioral roleplay for 16–19 not run end-to-end in this worktree
* Local Supabase CLI missing historically
* Extended stage14/15.2 check SQL diffs remain uncommitted (whitespace/parallel edits)
* Owner residuals from Stage 13: PHYSICAL OCR / two-device race / controlled push / REAL XLSX

## Hard bans (still)

No remote migration apply · No Edge deploy · No GitHub push · No real import · No service_role in Web

## Next (owner)

1. Review local commits on `feature/content-platform`
2. Authorize remote apply of prepared migrations (ordered)
3. Authorize Edge deploy for content/subject media if needed
4. Authorize push
