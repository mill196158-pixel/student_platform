# RF Infrastructure Migration Roadmap — Stage 21 (roadmap only)

Date: **2026-07-29**  
Branch: `feature/content-platform` (base `origin/refactor/chat-tab`)  
Worktree: `/Users/annasuvorova/student_platform_content`  
Related: `docs/master_roadmap.md` (Stage 21), `docs/content_platform/CONTENT_PLATFORM_SPEC.md` §9, `ACCEPTANCE_CHECKLIST.md` §AB.

**Status: SPEC DRAFTED** — planning document only. **Do not execute migration now.** No VPS provisioning, no DNS cutover, no remote apply in this session. Codex APPROVE required before any execution phase.

---

## 0. Purpose

Reduce operational dependency on Supabase-hosted infrastructure (`gwdanmwluhrcfxbnplwd`) by moving **primary backend** to Russian VPS / cloud while keeping the Flutter apps functionally equivalent.

This roadmap defines phases, preconditions, rollback, and honesty about **remaining external dependencies**.

---

## 1. Explicit caveats (non-negotiable disclosures)

| Topic | Reality |
|---|---|
| **Supabase dependency** | Russian backend **reduces** reliance on Supabase Postgres/Auth/Storage/Realtime/Edge, but migration is not «zero cloud» until all components are replaced and tested. |
| **FCM / APNs** | Push notifications remain **Google Firebase Cloud Messaging** and **Apple Push Notification service**. These are external to RF VPS and subject to their network policies. |
| **VPN / network independence** | **Full independence from VPN or foreign routing cannot be promised** without a **physical network test** on target mobile carriers and campus Wi‑Fi in Russia. Document expected DNS, TLS, and push behavior; run smoke on real devices before claiming compliance. |
| **Email / SMS auth** | If magic links or OTP providers are foreign, they remain external until replaced. |
| **CDN / object storage** | Public media may still use edge caching; plan for RF-accessible storage endpoints. |

---

## 2. Preconditions (before any migration work)

**Product stability first.** Do not start RF cutover until:

1. Content Platform Stages **14–19** are production-stable on current Supabase (or owner accepts frozen scope).
2. Stage 13 physical smokes completed or explicitly waived by owner for migration window.
3. Full **logical + physical backup** of Supabase project verified restorable.
4. Import Studio and moderation flows tested with real owner Excel (or migration accepts data freeze).
5. Written owner approval for migration window, downtime budget, and rollback authority.
6. Codex APPROVE on this roadmap and on each execution phase.

---

## 3. Target component map

| Current (Supabase) | RF target | Notes |
|---|---|---|
| PostgreSQL | PostgreSQL 15+ on RF VPS or managed RF Postgres | Extensions audit: `pgcrypto`, `uuid-ossp`, etc. |
| Auth (GoTrue) | Self-hosted GoTrue **or** custom JWT auth service | Must preserve `auth.uid()` semantics for RLS migration |
| Storage | S3-compatible (MinIO / RF object storage) | Private buckets, signed URLs, same path conventions |
| Realtime | Supabase Realtime fork **or** alternative (Centrifugo, etc.) | Chat/diary/group actions depend on this |
| Edge Functions | Deno workers on VPS **or** Node/Bun services behind reverse proxy | Push dispatch, signed media, cron triggers |
| Cron / workers | `pg_cron` + systemd timers **or** dedicated worker VM | Cleanup queues, deadline workers, media drain |
| Migrations | Flyway/sqlmigrate or Supabase CLI against RF DB | No edit of already-applied remote migrations |
| Secrets | Vault / env on VPS | No keys in Flutter Web |

---

## 4. Phased plan

### Phase 0 — Discovery and inventory (read-only)

**Goal:** Know what must move.

- [ ] Export schema-only + extension list from live Supabase
- [ ] List Edge Functions, cron jobs, webhooks, storage buckets
- [ ] Map Flutter/Admin env vars (`SUPABASE_URL`, anon key, etc.)
- [ ] Document RLS/RPC count and DEFINER functions
- [ ] Identify hardcoded Supabase URLs in repo
- [ ] Network diagram: client → API → DB → storage → push

**Exit:** Inventory doc + owner sign-off. **No provisioning.**

---

### Phase 1 — RF staging stack (parallel environment)

**Goal:** Empty RF stack that accepts migrations and runs app against **staging** data.

- [ ] Russian VPS (or RF cloud VM): sizing TBD after inventory
- [ ] PostgreSQL install, hardened `pg_hba`, TLS
- [ ] Auth service (GoTrue or equivalent) connected to same Postgres
- [ ] Object storage (MinIO or RF S3) with bucket policies mirroring production
- [ ] Realtime service wired to Postgres logical replication or polling strategy
- [ ] Edge/worker runtime for existing Deno functions
- [ ] Reverse proxy (nginx/Caddy): domain staging.`example.ru`, TLS Let’s Encrypt or RF CA
- [ ] **Backups:** daily pg_dump + WAL archiving; storage versioning; test restore
- [ ] **Monitoring:** uptime, disk, DB connections, error rate, backup success alerts

**Exit:** Staging app builds point to RF staging; smoke tests pass on empty DB.

---

### Phase 2 — Migration rehearsal (non-production)

**Goal:** Prove data move without touching production users.

- [ ] Anonymized or snapshot subset copy Supabase → RF staging
- [ ] **Integrity checks:** row counts per table, checksum samples, FK validation
- [ ] Run application test suite + manual admin/student flows
- [ ] Realtime: chat message round-trip, diary update, group action card
- [ ] Storage: signed upload/download for news/content/subject media
- [ ] Push: FCM/APNs from RF worker using **same** Firebase/APNs credentials (external)
- [ ] Document drift fixes (extension gaps, timezone, collation)

**Exit:** Rehearsal report with pass/fail per subsystem. Repeat until green.

---

### Phase 3 — Production sync and read-only window

**Goal:** Minimize cutover data loss.

- [ ] Announce maintenance window
- [ ] Final incremental sync Supabase → RF (logical replication or pg_dump + delta)
- [ ] **Temporary read-only** on Supabase production (disable writes via RPC flag or maintenance mode in app)
- [ ] Final integrity checks (counts, critical invariants: enrollments, teams, messages)
- [ ] Freeze new admin publishes during window (communicated)

**Exit:** RF DB byte/logically consistent with frozen Supabase; production still on Supabase until cutover flip.

---

### Phase 4 — Cutover

**Goal:** Switch live traffic to RF.

- [ ] Update DNS / Flutter config: production `SUPABASE_URL` → RF API gateway (or renamed env `API_BASE_URL`)
- [ ] Deploy Admin Web + mobile release or remote config flip (owner-controlled)
- [ ] Enable RF workers/cron; disable Supabase Edge cron to avoid double push
- [ ] Smoke: login, home promo, chat send, push receive, import dry-run read
- [ ] Monitor 24–72h elevated; on-call defined

**Rollback trigger examples:** auth failure spike, message loss detected, storage 403 widespread, push complete failure.

---

### Phase 5 — Rollback procedure (must be written before Phase 4)

**Goal:** Revert to Supabase within agreed RTO.

- [ ] Re-enable Supabase writes if read-only was used
- [ ] Revert Flutter/Admin config to Supabase URLs (keep previous release binaries)
- [ ] DNS rollback plan documented (< 30 min target for config revert)
- [ ] Accept possible **dual-write gap**: events during RF primary may need manual reconcile or be lost — rehearse to minimize window
- [ ] Post-mortem template

**Exit:** Tested rollback on staging at least once.

---

### Phase 6 — Decommission Supabase (optional, later)

Only after extended stable period on RF:

- [ ] Archive final Supabase backup offsite
- [ ] Revoke keys; downgrade Supabase project
- [ ] Update docs and runbooks

Not required for initial migration success.

---

## 5. Flutter and Admin configuration updates

| Artifact | Change |
|---|---|
| Mobile `lib/` env | Replace or abstract Supabase URL/anon key → config layer supporting RF gateway |
| Admin Web | Same; no `service_role` in client (unchanged rule) |
| Deep links / universal links | Re-verify after domain change |
| Storage signed URL host | Must match RF storage CDN/gateway |
| Realtime websocket URL | Update client initialization |
| CI secrets | New staging/prod keys in CI vault |

Prefer **build flavors** or remote config for URL flip without store resubmission if already supported; otherwise plan app release alongside cutover.

---

## 6. Backups and monitoring (production requirements)

**Backups**

- PostgreSQL: daily full + continuous WAL; encrypted at rest; off-VPS copy
- Object storage: versioning + lifecycle; cross-region copy within RF if available
- Config/secrets: documented restore, not in git

**Monitoring**

- HTTP 5xx rate, p95 latency
- DB connections, replication lag (if used)
- Disk > 80% alert
- Backup job failure = page owner
- Push queue depth and failure rate
- Certificate expiry

---

## 7. Domain and TLS

- Production API: `api.<product-domain>.ru` (example)
- Admin: `admin.<product-domain>.ru`
- Storage: `media.<product-domain>.ru` or path on API domain
- TLS 1.2+; HSTS after cutover stable
- Document certificate renewal automation

---

## 8. Integrity checks (checklist at each rehearsal/cutover)

- [ ] Table row counts vs source (tolerance documented for volatile tables)
- [ ] Sample hash: messages, users, enrollments
- [ ] No orphaned FKs
- [ ] RLS smoke: student cannot read other group’s content
- [ ] RBAC admin permissions unchanged
- [ ] Feature flags readable
- [ ] Cron jobs registered and last run successful
- [ ] Storage object count ≈ source (allow cleanup queue delta)

---

## 9. What this roadmap does **not** do now

- Provision Russian VPS
- Apply migrations to RF Postgres
- Change production Supabase
- Push Flutter builds to stores
- Guarantee VPN-free operation without physical network test
- Migrate Firebase/APNs to RF (not realistically possible — remain external)

---

## 10. Acceptance mapping

Checklist §AB items map to §3–§8. Mark checklist `[x]` only after this doc + Codex APPROVE. Execution phases require separate owner authorization per phase.

---

## 11. Open decisions (owner / Codex)

- [ ] Exact RF hosting provider and legal entity for data processing
- [ ] GoTrue self-host vs custom auth
- [ ] Realtime technology choice
- [ ] Acceptable maintenance window length
- [ ] Whether Supabase stays warm standby vs cold backup after cutover

**Reminder:** Migration execution is **explicitly out of scope** until product stable and owner commands go-ahead.
