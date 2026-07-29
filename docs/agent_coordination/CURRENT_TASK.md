# CURRENT_TASK

* Status: **STAGE_16_3_REFERENCE DONE (local)** / Codex **APPROVE**
* Active Stage: prepare **Stage 17 — Vacancies** (scaffold exists uncommitted; needs full review)
* Branch: `feature/content-platform`
* Worktree: `/Users/annasuvorova/student_platform_content`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote: `gwdanmwluhrcfxbnplwd` (**no apply / no deploy / no push**)

## Just closed

* Stage **16.3** — Codex **APPROVE** → local commit (this slice)
* Stage **16.2** — Codex **APPROVE_WITH_NOTES** → `5bdccfb`
* Stage **16.1** — Codex **APPROVE** → `6e03828`

## Stage 16.3 delivered (local)

* Categories SoT + schema v2 + bundle RPC + corrections hardening
* `admin_set_content_audience` reference JSON wrap + Admin refetch fallback
* content-media Edge (upload/finalize/download/cleanup) — path service-side; MIME fail-closed; pending-only leases
* Admin reference editor: typed blocks, media upload, category create/edit/status/reorder
* Mobile Help: `ReferenceService` dual-read + `ContentMediaService` open asset/url/cta
* Security review + roleplay assertive; Dart tests green
* ACCEPTANCE §S marked done after Codex APPROVE

## Next (strict order, separate commits)

1. **Stage 17** — full review of vacancy scaffold → APPROVE → separate commit
2. **Stage 18** — full review of reviews/points/moderation scaffold → APPROVE → separate commit
3. **Stage 19** — full review of Import Studio scaffold → APPROVE → separate commit

Do **not** mark §T/§U–§W/§X–§Y done until tests + Codex APPROVE per stage.

## Working tree note

Uncommitted Stage **17–19** scaffolds may remain after the 16.3 commit (vacancies / reviews / import studio). Keep them out of the 16.3 commit.

## Codex verdicts

| Slice | Verdict | Commit |
|---|---|---|
| 16.2 impl | APPROVE_WITH_NOTES | `5bdccfb` |
| 16.3 plan | APPROVE | (SPEC) |
| 16.3 impl | **APPROVE** | (this commit) |

## Hard bans

No remote migration apply · No Edge deploy · No GitHub push · No real import · No merge into `refactor/chat-tab` · No checklist DONE without tests + Codex APPROVE
