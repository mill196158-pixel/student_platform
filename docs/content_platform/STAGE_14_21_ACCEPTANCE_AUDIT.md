# Stage 14–21 acceptance audit

Date: **2026-07-29**  
Branch: `feature/content-platform`  
Local HEAD at audit start: `7b25ca5`  
Codex overall verdict: **APPROVE** (no remaining P0/P1)  
Worktree: `/Users/annasuvorova/student_platform_content`  
Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`  
Remote: `gwdanmwluhrcfxbnplwd` — **no apply / no deploy / no push**

Rule: map each `ACCEPTANCE_CHECKLIST.md` section to evidence. Do **not** mark unimplemented work as done.

## Commit chain (local, Content Platform)

| Slice | Commit | Codex |
|---|---|---|
| Docs gate / Stage 20–21 initial | `e279c53`, `5f23429` | APPROVE |
| Stage 14A/B | `2588581`, `691f43e`, `74c779d` | APPROVE |
| Stage 15.1–15.3 | `183efc8`, `001e1f0`, `cebfcf5` | APPROVE |
| Stage 16.1–16.3 | `6e03828`, `5bdccfb`, `65039d4` | APPROVE / NOTES |
| Stage 17 | `0b4a040` | APPROVE |
| Stage 18 | `8a3f533` | APPROVE |
| Stage 19 foundation | `716c604` | APPROVE_WITH_NOTES |
| Dirt corrective | `91325f1` | APPROVE |
| Stage 19 completion | `544fcd4` | APPROVE |
| Stage 20–21 refresh | `7b25ca5` | APPROVE_WITH_NOTES |

## Checklist section map

| § | Topic | Status | Evidence |
|---|---|---|---|
| A | Process & bans | **Mostly DONE**; overall Codex review this audit | Hard bans held; per-slice Codex done; A.24–A.29 process items synced after audit |
| B | Read-only audit | **DONE** (surfaces studied) | `AUDIT_EVIDENCE_2026_07_29.md` |
| C–H | Stage 14 schema/RPC/audience | **DONE (local)** | `20260729133000_stage14_managed_content_foundation.sql` + stage14 checks + Codex APPROVE |
| I | Version restore Admin UI | **PARTIAL** | SQL restore exists; Admin version history UI for managed content missing |
| J | Mobile RPCs/client | **PARTIAL** | Services + tests; event retention cron not wired; N+1 artifact informal |
| K | Assets Stage 14 wording | **PARTIAL→covered by 16.2/16.3** | Signed media Edge local; remote deploy pending owner |
| L | Stage 14 security close | **PARTIAL (local)** | security_review + roleplay **authored/static-reviewed** (live `psql` not run this audit); Codex APPROVE on foundation slice; secret scan = env-key reads only |
| M | Stage 14.1 demo governance | **PARTIAL — NOT CLOSED** | Inventory/archive/origin yes; Admin «Демо» filter + safe-delete UI no; no Codex APPROVE 14.1 |
| N–P | Stage 15.1–15.3 | **DONE (local)** | Checklist `[x]`; commits above |
| Q–S | Stage 16.1–16.3 | **DONE (local)** | Checklist `[x]`; media Edge local only |
| T | Stage 17 vacancies | **DONE (local)** | Checklist `[x]` |
| U–W | Stage 18 | **DONE (local)** | Checklist `[x]` |
| X–Y | Stage 19 Import Studio | **DONE (local)** | Checklist `[x]`; 9 domains apply; rollback-safe subset |
| Z | Design contract | **PARTIAL** | Shared renderers + widget tests; no goldens; many UX matrix items aspirational |
| AA | Stage 20 AI spec | **DONE (docs)** | `AI_ASSISTANTS_SPEC.md` — no paid AI |
| AB | Stage 21 RF roadmap | **DONE (docs)** | `RF_INFRA_MIGRATION_ROADMAP.md` — no infra execution |
| AC | Per-slice engineering | **Recorded per slice** | See final gates below |
| AD | Final stop | **THIS AUDIT** | Owner report; tree clean after audit commit |

## Explicitly NOT closed

1. **Stage 14.1** — Admin demo filter + managed-content safe-delete UI + Codex APPROVE 14.1.
2. **Remote apply / Edge deploy** for Stages 14–19.
3. **Real Excel import** via Import Studio.
4. **Paid AI** (Stage 20) and **RF migration execution** (Stage 21).
5. **Design contract Z** full matrix (goldens, device sizes, a11y suite).
6. **Managed content Admin version history UI** (SQL ready).

## Final local gates (2026-07-29)

| Gate | Result |
|---|---|
| `packages/student_ui` tests | **68/68 PASS** |
| Main app content tests (promo/feed/vacancy) | **24/24 PASS** |
| Admin Import Studio tests | **22/22 PASS** |
| Admin content editors (promo/feed/reference/vacancy) | **PASS** |
| Full `admin_console` suite | **FAIL** — legacy `news_editor_image_test` / `admin_auth_session_test` / `widget_test` (pre-existing vs Content Platform slices; not Stage 19 regressions) |
| `dart analyze` Import Studio | **no errors** after FilePicker 11 API fix |
| `student_ui` analyze | warning unused `_Pill`; info dangling doc |
| Admin Web release build | **PASS** (`flutter build web --release`) |
| `git diff --check` on Content Platform range | trailing WS noise from CRLF in vacancy test → normalized LF |
| Secret scan | No hardcoded keys; `SUPABASE_SERVICE_ROLE_KEY` only via `Deno.env` / script env (expected) |
| Push / remote apply / Edge deploy / real import | **not performed** |

## Owner next (blocked on permission)

1. Remote apply Stage 14–19 migrations + deploy content/vacancy/subject media Edges.
2. Optional Stage 14.1 completion (demo filter + safe-delete UI).
3. Physical smoke after remote apply.
4. Real XLSX Import Studio dry-run → apply (owner-gated).
5. Stage 21 open decision: rollback RPO / reverse-sync before any RF cutover.
