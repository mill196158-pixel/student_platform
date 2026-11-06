# Offline and recovery QA — 6 November 2026

This is a working checklist, not a release approval. Preserve the original
AVD backup, the original-project file backup, and the saved Git stash.

## Experimental checkpoint

The unfinished integrated candidate is retained for QA, not release. Offline
admission/UI and Android durable forwarding require the
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
- Cold offline behavior is available only in the explicitly flagged QA candidate;
  full application coverage and the crash-during-revalidation regression remain
  incomplete. The normal build must not be described as fully offline-ready.
- Durable forwarding is experimental and disabled by default; an unknown send
  result still needs explicit handling. No exactly-once claim is made without
  verified server idempotency.
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

## QA2 device observations

The QA2 Android candidate used the three explicit defines listed above. Before
installation, two data archives were created, read in full, and checked by
SHA-256. Restoration from those archives was not tested. They are separate
from the earlier pre-incident AVD backup; an APK alone is not a data backup.

On the emulator, a cold start without network opened the cached home, saved
chats, a previously warmed schedule, and the previously saved QR image. The QR
opened fullscreen on a white background, and Android Back returned from the
viewer. Pinch-to-zoom was not checked on the device.

For a non-empty schedule check, two test lessons on 19 June 2026 were opened
online (`qa2-online-schedule-june19.png`). After force-stopping the app and
turning the network off, the same times, teachers and rooms appeared offline
(`qa2-offline-schedule-june19.png`). This month was warmed manually, so this
does not establish that automatic warming works. The network was restored.

In QA2, news and advertising disappeared offline, and the offline interface remained
simplified. Installation used `install -r`, so these observations do not prove
that automatic warming works from a genuinely clean cache. They also do not
prove that every chat, attachment, or screen works after a cold offline start.

In the guarded QA notification path, opening a push without a verifiable
`notification_id` is unavailable, as are group-action deep links; chat prewarm
from guarded push is disabled. Firebase SDK and real notification delivery were
not verified by these observations. The normal build and the complete product
remain unfinished; this QA candidate is not a release approval.

## QA3 and QA4 device observations

Both candidates used the explicit QA defines `SQLITE_POLICY_QA`,
`OFFLINE_UI_QA`, and `FORWARD_DURABLE_ANDROID_QA`. After a real online warm,
QA3 failed on cold offline start because Android CursorWindow could not read a
large image BLOB from SQLite. The snapshot used in the next check was saved
by QA3.

QA4 was installed over QA3 with `install -r`. On a cold start without network,
the home screen opened with a news item and its image, tasks and a banner
(`qa4-cold-offline-home.png`). The saved news opened with its text and image
(`qa4-offline-story.png`). The network was restored after the check. Because
QA4 reused QA3 data, this does not prove automatic prewarming from a clean
installation or complete offline coverage.

Before QA4 installation, a data archive was read and its SHA-256 checked;
restoration from it was not tested. The guarded push limitations described
above remain open. These observations concern a flagged QA candidate, not the
ordinary build or a release approval.

## QA5 device observations

After a cold offline launch using already warmed data, the same saved subject
chat opened through three paths: Base → subject, Learning → subject, and the
chat list. Messages and the saved QR image were visible in all three checks
(`qa5-offline-base-subject.png`, `qa5-offline-learning-subject.png`,
`qa5-offline-list-subject.png`). A repeat entry produced a settled screenshot;
frame-by-frame opening latency was not measured. The network was restored.

In a separate live transition check, the subject chat was opened online
(`qa5-live-subject-online.png`); after Wi-Fi and mobile data were turned off,
the chat remained on screen (`qa5-live-subject-disconnected.png`). Returning
and opening that same chat again offline showed messages and the QR image
after five seconds (`qa5-live-subject-reopen-offline.png`). This does not
establish frame-by-frame instant rendering. The network was restored.

The earlier `qa5-live-online-before-drop` screenshot followed an incorrect
sequence of taps and does not establish a reproducible token-refresh defect.

A real online screen recording of reopening the chat
(`qa5-online-chat-reopen-20261106.mp4`) shows `Загрузка…` in
`qa5-reopen-frames/frame-02.png`, followed by the QR image in
`qa5-reopen-frames/frame-03.png`. Instant image display has therefore not been
achieved in this check.

The experimental refresh-grant work is QA-only. Its synthetic SDK and SQLite
suite reported 31/31 passing, including unchanged-then-rotated credentials.
It does not restore the online UI capability after rotated credentials. The
crash window between SQLite commit and stale cleanup remains unproven; these
tests do not establish production readiness or Android device behavior.

The assignment card was unavailable, and DOCX was represented only by text;
opening the document was not verified. On QA5 the directory header overlapped
the Android status bar. A SafeArea fix was made after that build, but its
appearance on the emulator has not yet been checked.

The recorded candidate APK SHA-256 starts with `08F1`; the data archive hash
starts with `b796`. The archive was read and its hash checked, but restoration
was not tested. These are flagged QA observations on previously warmed data,
not proof of clean-install prewarming or complete offline coverage.

## QA7 chat re-entry observations

On one previously opened team chat, re-entry was recorded online and then
again after disabling Wi-Fi and mobile data without restarting the app:
`qa7-online-chat-reopen-20261106.mp4` and
`qa7-offline-chat-reopen-20261106.mp4`. The QA build included the earlier QA
defines and `CHAT_REENTRY_GATE_QA`.

In the inspected 10 fps frames (`qa7-reopen-10fps` and
`qa7-offline-reopen-10fps`), the loading dove appeared briefly before the
content. From frame 12 through frame 30, the chat and QR remained visible;
no separate image loader was visible in those inspected frames. These are two
scenarios for one chat, not proof about every frame, every chat, or cold-start
paths. The network was restored after the check.

The QA7 candidate SHA-256 starts with `804EC`; the data archive hash starts
with `8310`. The archive was read and its hash checked; restoration was not
tested.

## Shared UI golden investigation

`packages/student_ui/test/visual_parity_golden_test.dart` ran without updating
goldens: 8 cases passed and 12 pixel comparisons failed. The failures cover
home image-full, image-overlay and end-of-page promo, jobs board and detail,
and help article at both 390×844 and 430×932. An initial `--no-pub` run could
not resolve the package-local `lottie` configuration; `flutter pub get
--offline` restored dependencies before the reported run.

All six inspected 390×844 golden files were last changed in `ef2e1a3`. The
later `e2b883f` replaced the preview theme with `ProductTheme` while updating
only the profile and help-browse golden images. In the home image-full,
image-overlay and help-article comparisons, a background pixel changed from
RGB (245, 245, 245), the earlier `#F5F5F5` theme, to RGB (245, 247, 251),
the current `#F5F7FB` canvas. This explains a large portion of those pixel
diffs. Jobs board keeps the same sampled background but visibly differs in
text styling; correctness and the full cause of each mismatch are not proven.

The test images show square glyphs and the harness does not explicitly load a
font, so these captures do not verify real typography or establish a
Windows/Mac difference. Review the current real screens and set up a stable
test font/environment before intentionally updating any baselines. No golden
was updated in this investigation.

Evidence SHA-256, recorded at inspection:

- `test/goldens/home_image_full_390x844.png`:
  `75f4718a12ee2180874fc05d6624e9ca1bd9e691c7fdbae5011f9f3a7a41b009`.
- `test/failures/home_image_full_390x844_testImage.png`:
  `178663b046f2179a141ab5a7326a447ef4b394b034f77de56fe896cf31afe564`.
- `design_preview/optimizer_qa/golden_comparison.png`:
  `76b7c9b367ff381a640d7c3772667e4bfe878fb6a4736c0f00006dfc8e458bee`.

The first two paths above are relative to `packages/student_ui`; the last is
relative to the repository root. Before the run, the existing 64 failure
artifacts were copied to
`design_preview/optimizer_qa/student_ui_failures_backup_6e312277ca0341f9b0fad7778f5f08d1`
and each copy matched its source SHA-256. Those artifacts contain prior runs
as well as the current failures and should not be counted as a test result.
