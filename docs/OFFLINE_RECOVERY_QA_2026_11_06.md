# Offline and recovery QA — 6 November 2026

This is a working checklist, not a release approval. Preserve the original
AVD backup, the original-project file backup, and the saved Git stash.

## Experimental checkpoint

The unfinished integrated candidate is retained for review, not release or
installation. Offline admission/UI and Android durable forwarding require the
explicit defines `SQLITE_POLICY_QA`, `OFFLINE_UI_QA`, and
`FORWARD_DURABLE_ANDROID_QA`; all default to false. Some ordinary online paths
also changed and have not received complete end-to-end review. Do not assume a
normal build includes the requested offline behavior. Downgrading an app that
has created durable queue entries requires a separately verified recovery plan;
the old APK cannot see those entries. Existing user data must be preserved.

## Verified on the intermediate Android build

- The original app package was reinstalled and the supplied test account signed
  in again. This does not restore the previous private app data or cache.
- The previously reported unavailable group-chat cards and orphan date did not
  appear; a message remained visible. The reported nested forward showed an
  author. No test message was sent.
- The QR image in the reported subject chat was visible on entry and re-entry
  with the network on. Frame-by-frame latency and cold offline are not proven.
- The visible beach promotion matched the published `home_promo_v1` record
  checked read-only; possible unpublished drafts were not checked.
- Production `chat-file-access` was updated to v4 with `verify_jwt=true`; a
  permitted file, a typed denial and an unauthenticated request were checked.
  The previous v3 source files and manifest were preserved for rollback.

## Open or limited

- A Flutter integration test unexpectedly removed the original Android package.
  Its app-private directory was absent afterwards; no Android restore set was
  available. A pre-incident AVD snapshot exists, but its app data has not been
  recovered. APK files are not backups of app data.
- Cold offline startup, previously opened chats, attachments after process death,
  and the existing crash-during-revalidation regression remain incomplete.
  The SQLite and transport work is isolated infrastructure, not runtime admission.
- Both forward composer paths still need a durable handoff and safe handling of
  an unknown send result; no exactly-once claim without server idempotency.
- Fullscreen revocation and clipboard provenance, including legacy Android
  clipboard data and late results, require final integrated device verification.
- The admin image optimization and guarded replacement are not deployed. The
  test account lacks content publishing permissions; do not bypass roles or
  describe previously published objects as optimized.
- Recheck team, message-list and notification chat routes; PNG zoom/swipe and
  original quality; DWG/DOCX; light/dark/system and Base; diary collapse and
  deferred points; notification read/mute/badge; schedule matching and
  practices; links; and phone/tablet/desktop layouts on the final build.

The reproducible pending-file test is `test/chat_file_crash_offline_blocker_test.dart`.
It is skipped by default and can be run with
`flutter test --dart-define=RUN_OFFLINE_CRASH_REGRESSION=true test/chat_file_crash_offline_blocker_test.dart`.
It models a restart; it is not a real process-kill test.
