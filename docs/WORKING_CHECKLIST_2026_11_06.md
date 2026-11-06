# Current delivery checklist — 2026-11-06

This checklist records the outstanding user-facing work, not release approval.
All ordinary-client claims require tests of the exact build on the existing
emulator. Experiments guarded by QA flags do not satisfy ordinary-client items.

- [ ] Cold launch after a prior online session: preserved home, schedule,
  chats, assignments and available attachments; no offline password login.
- [ ] Repeat entry through messages, teams and materials: measure first
  frames for cached images and avoid an unnecessary loading transition.
- [ ] Forwarded PDF and other saved attachments: exact identity, account
  isolation, offline opening and safe behavior on denial/reconnect.
- [ ] Preserve unconfirmed messages and attachments across trimming,
  restart, server refresh and account/session changes. Local trimming fix
  is tested; cold-first hydration and session changes remain open.
- [ ] A real shared 500,000,000-byte budget across temporary caches, with
  physical SQLite/WAL accounting and protected drafts, security state,
  explicitly offline files and server originals outside automatic deletion.
  Prototype accounting alone does not implement this limit.
- [ ] Active admin image optimization in news, home and profile editors,
  including a safe deployment/launch path and testing without replacing real
  published assets. Previously published examples are not a full inventory.
- [ ] Complete accessible functionality, notifications, theme and screen
  verification previously requested; do not infer unvisited screens passed.
- [ ] Verify the final ordinary Android build online, repeated chat entry,
  force-stop/cold offline and reconnection; preserve rollback and app data.
- [ ] Run required tests on the final candidate, push the reviewed commits,
  verify the exact remote SHA and document remaining unverified scenarios.

Existing evidence and known constraints: `OFFLINE_RECOVERY_QA_2026_11_06.md`,
`FORWARDED_PDF_DEVICE_QA_2026_11_06.md`, `IMAGE_REENTRY_DEVICE_QA_2026_11_06.md`,
`REENTRY_TIMING_DIAGNOSTIC_2026_11_06.md`, and
`BOUNDED_PUBLIC_PREVIEW_CACHE_PLAN_2026_11_06.md`. The test user lacks the
admin content permissions required for publication; do not bypass RBAC.
