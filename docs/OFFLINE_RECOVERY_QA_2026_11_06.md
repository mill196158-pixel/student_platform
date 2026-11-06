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

## Emulator state, 2026-11-06 11:39

Candidate 9 (`b5ad107`, APK SHA-256 `ed319aa2e487f3213278fb4aba4bd7b30903d7c8481ec938a094d5c5e699ba0e`) is installed with `SQLITE_POLICY_QA`, `OFFLINE_UI_QA`, `FORWARD_DURABLE_ANDROID_QA` and `CHAT_REENTRY_GATE_QA` enabled. Wi-Fi and mobile data were enabled and the Android network was validated. After installation the app showed its loading screen and then the signed-in home (`qa9-after-20261106.png`); this does not establish that a real token refresh occurred or that push routes work. Profile opened; the attempt to open messages returned to home and needs investigation. This is not a release build. Before installation the app data archive `emulator-data-before-candidate9-20261106.tar` was checked for readability, SHA-256 `5695b7053ff6520b18d889fbd5cee7e366d0a6f06259b7b995159dc0c6122e71`; restoration has not been tested. Prior to restoring the normal build, the archived durable forward tables contained zero pending, sent, terminal, or legacy-import entries. The normal build was then opened on home. The candidate remains subject to the known push and offline limitations above.

Follow-up on candidate 9: repeating profile → messages opened the list (`qa9-chat-retry.png`), so the earlier return to home was not consistently reproducible. The initially rendered list showed raw forwarded payload text before later resolving it; it also showed summaries for card messages. Opening the previously visited subject chat still displayed the image placeholder (`qa9-subject.png`). The app later returned from the chat to the message list while testing; its cause is not established. No image was sent and the photo-choice UI has not yet been verified. These observations preclude claiming instant display or stable navigation.

On a second subject-chat open, the image was visible behind the photo attachment choice (`qa9-photo-retry.png`), and tapping the gallery icon opened the choices for compressed photo or unchanged original. The dialog was dismissed; no gallery image was selected and no upload was made. This verifies the choice is reachable, not that Android compression/upload succeeds. The prior placeholder on the first open still stands.

Current emulator handoff (2026-11-06 approximately 11:43): candidate 9 was replaced using `adb install -r` with the previous normal APK, SHA-256 `88b50138c7531740877aaf5edfd2c10f95418531862edd256c5c34afb4c55a4f`; candidate QA flags are absent from that APK. Network was left enabled. Before replacement, `emulator-data-after-candidate9-20261106.tar` was readable, SHA-256 `d7318ab53beb24685c9ecc7dac6e430ac2771df72bcc644e0b7bdb0c9811b163`, and the durable forward item/sent/terminal/legacy-import tables each contained zero rows. Restoration was not tested. A synthetic GoRouter lifecycle test found that token rotation can reset the selected home tab and leave imperative routes visible above a blocked QA shell; it did not reproduce the chat-to-list return and no actual device refresh event was proven. Candidate 9 must not be considered a release.
The restored normal build subsequently displayed signed-in home (`normal-after-qa9-20261106.png`).

Published-image recheck after user reuploads, 2026-11-06: read-only inspection of the authorized Android app cache found the new news asset as verified JPEG 549×364, 39,318 bytes, SHA-256 `d65fdaa33f8f7ea1df3e7cce10c3f9e25047e036a0b3f475fd48af94aef0b71a`, and the new home/profile promo assets as JPEG 678×452, 47,022 bytes, SHA-256 `7b49513d428ef19937da7c14b5d3b87090978e96eea6d0f0143cfe13c41ff7f7`. The news detail and the home promo rendered (`current-published-news-20261106.png`, `normal-after-qa9-20261106.png`). The expanded news image looks a little soft at this emulator size; no original-side quality comparison was performed. No server images were modified by this check. This verifies only these three published references, not all media or first-load latency.

Full default-define root suite, 2026-11-06: 1,067 passed, 2 skipped, 5 failed (`design_preview/optimizer_qa/full-suite-20261106-final.log`). Failures: `dm_forward_durable_widget_test.dart` send expectation after hit-test warning, three `home_cache_only_widget_test.dart` cases, and `reentry_image_gate_test.dart` session-changed error. Root causes and isolated reruns were pending at this point. This run includes the uncommitted diagnostic `qa_refresh_route_lifecycle_test.dart`; it is not a clean committed-source release certification.

Failure follow-up: isolated affected tests passed after test-only corrections: 8 passed and 1 QA-only scenario skipped in the default build, with that reentry file passing 5/5 under `CHAT_REENTRY_GATE_QA=true`. Home fixtures now provide `canRead`; the forward test waits until the real send control is hit-testable after the snackbar; the QA-only reentry assertion is explicitly skipped without its define. These targeted results do not replace a rerun of the whole suite. Privacy/lifecycle and device image-load failures remain open.

A second root suite was started against tracked HEAD `da50313` with unrelated untracked diagnostic tests temporarily moved aside and subsequently restored. It reached 668 passes and 2 skips without a reported assertion failure, then stopped making progress for over two minutes in `durable_forward_sqlite_ffi_test.dart` at `real SQLite reopens unknown then confirmed without resending`; the run was interrupted and is incomplete (`full-suite-20261106-head-rerun.log`). The first full run completed that test. The precise stalled await has not been identified; no clean full-suite pass is claimed.

The SQLite scenario that stalled in the second full run subsequently passed in isolation with `flutter test --no-pub test/durable_forward_sqlite_ffi_test.dart --plain-name 'real SQLite reopens unknown then confirmed without resending'` (1/1). This does not identify the full-run stall or turn the interrupted run into a pass.

Full default-define root suite rerun: tracked HEAD `966b7e7`, unrelated untracked diagnostic tests moved aside and restored, `flutter test --no-pub --reporter expanded --concurrency=2`: **1,068 passed, 3 skipped**, 0 failed, log `full-suite-20261106-head-concurrency2.log`. The QA-only image reentry case is one of the skipped tests and passed separately with `CHAT_REENTRY_GATE_QA=true`; this is not a full run of a QA-flagged candidate.

Current work ownership and remaining acceptance: root owns exact APK/defines, emulator and Git; cold_start owns automatic image preparation in the three admin upload routes, without production publishing; offline_files owns scoped image prewarm/reentry and authorization tests; review_cold owns investigation of token rotation/nested-route privacy and navigation with draft preservation, with independent review required before integration. Remaining acceptance: resolve QA lifecycle and push compatibility without unauthorized writes; verify first and repeat chat rendering, offline cold start and attachment behavior on the exact installed candidate; rerun full suite on that candidate's flags; verify admin picker routes without uploading production fixtures; preserve rollback and publish only reviewed commits. The current emulator remains on the prior normal APK with network enabled, not the experimental candidate.

Emulator update: the normal debug APK built from `f378d1f` without experimental defines was installed with `adb install -r`; SHA-256 `918103a835ebb0820f60a0af1e353dc1cdec3fc451a998f434563213d22a0c05`. Before installation the readable app-data archive `emulator-before-normal-f378d1f-20261106.tar` had SHA-256 `d2a203b13f14eadbbb293185fcfdb30bdd3d2322671d40ed9804973d469bcc52`, and durable forward item/sent/terminal/legacy-import counts were all zero; restoration was not tested. Signed-in home opened (`normal-f378d1f-home-ready.png`), then chat list opened (`normal-f378d1f-chats.png`): a legacy cached forward preview still initially showed raw `__FG__` text. Network remained enabled. This normal build has experimental offline defines off and is not the requested full offline candidate.
Normal f378d1f subject-chat smoke: the first captured frame after opening showed loading placeholders (`normal-f378d1f-subject.png`), followed by messages and QR (`normal-f378d1f-subject-ready.png`). This is direct evidence that the requested instant opening remains unmet in the installed normal APK; no message was sent.

Admin automatic image preparation checkpoint `1a63e77`: three editor routes prepare eligible JPEG automatically, then show size and comparison and let the user choose the compressed copy or original; PNG lossless and unsupported cases follow their respective validation/fallback paths. Reported tests: 26 VM/widget checks and an isolated compiled Chrome picker-to-worker fixture passed (synthetic JPEG 5,095,076 → 1,062,643 bytes; original byte-identical). The actual OS file dialog, user's running editor, other platforms and real QR readability were not tested. This code is pushed to the experimental branch, not installed or deployed into the active admin window.

Admin image checkpoint `5e77c7b` is pushed to `codex/offline-integration-wip`. Reported scoped verification: 27 VM tests and exact-source isolated Chrome synthetic picker-to-worker tests; JPEG 5,095,076 → 776,714 bytes, PNG alpha 6,003,000 → 652,730 and WebP alpha 1,459,572 → 646,632; alpha was compared at unchanged synthetic dimensions, original bytes/MIME retained, unsupported metadata/animation fell back. The 512 KiB objective was not achieved in these examples without exceeding quality checks. Real photos, OS chooser, QR readability and live admin were not checked; no deployment or publication was performed. `image_prewarm_wip_20261106_155248` holds an unapproved experiment whose first-pump unsupported test failed; its default-active changes were restored out of the working tree. Experimental rotation `709dd10` remains default-off and not approved for device use.

Nearest integrated-candidate gate (2026-11-06): (1) offline_files owns the observed image-load regression: finish exact-owner obtainKey→load fence and pixel/403/ABA regression, have it reviewed, then integrate the tested files; acceptance requires real first/reentry and cold-offline chat+attachment on device. (2) review_cold owns initial-refresh recovery: preserve the approved 42 targeted tests and add linked observer/route evidence, then final scoped review; acceptance requires real cold offline and online session recovery without lost navigation/draft. (3) cold_start owns push route: fix failing read-only DirectChat fixture/drain and implement real DM/team/group actions; neutral hint is not acceptance. (4) root owns one frozen candidate, full tests, backup/empty-queue preflight, same emulator and Git. Proposed experimental defines are SQLITE_POLICY_QA, OFFLINE_UI_QA, FORWARD_DURABLE_ANDROID_QA, CHAT_REENTRY_GATE_QA, QA_ROTATION_NAVIGATION_EXPERIMENT and QA_LOCAL_IMAGE_PREWARM, all true, with push flag only after real targets pass; this is a test proposal, not an approved or built release. Use no QA flag on an everyday build until its linked behavior passes. Current normal APK is f378d1f with all these defines off. Admin release build is separate and does not block Android testing; it has not updated the live admin.

Startup-only device QA, 2026-11-06: APK from `4e21245` SHA-256 `836299ffddfe325e52b8239bc73c9d4d0f48824a8f0b9f4de38d339a22d59a24`, defines `SQLITE_POLICY_QA`, `OFFLINE_UI_QA`, `FORWARD_DURABLE_ANDROID_QA`, `CHAT_REENTRY_GATE_QA`, `QA_ROTATION_NAVIGATION_EXPERIMENT` true; prewarm/push experimental flags absent. Before install, the app was stopped and data archived at `emulator-before-startup-qa-4e21245.tar` SHA-256 `e6bccfeb02f55e7ffa1bdb8f2724ab5465beb96a3fdb9a52ea013187887e24ed`; all four durable forward tables were empty. Wi-Fi and mobile data were disabled, Android reported `Active default network: none`, and the app was launched from stopped state. Previously cached signed-in home, news image, tasks and promo were visible (`startup-qa-4e21245-offline.png`); no other screen was checked in this run. The QA app was force-stopped while still offline; `emulator-after-startup-qa-4e21245.tar` SHA-256 `c88709676263a68ed54c6a0c5530a81e4e25daadc9fcec380f3b207d71f894c8` had all four forward tables empty. Reinstalled normal f378d1f with `adb install -r`, then restored network and launched it. Archive restoration was not tested. This is not an online refresh test, clean-install test, full offline or a release approval.

Combined candidate `ff840c4` (SHA-256 `70f7440bf008af3527f12abbb1725c47aee07af48b8dfb3fcaa114cbb2ffe431`) was built with six defines: SQLITE_POLICY_QA, OFFLINE_UI_QA, FORWARD_DURABLE_ANDROID_QA, CHAT_REENTRY_GATE_QA, QA_ROTATION_NAVIGATION_EXPERIMENT, QA_LOCAL_IMAGE_PREWARM; new push flags absent. The exact tracked-source full suite with these defines passed 1,086 tests with 2 skipped (`combined-qa-ff840c4-suite.log`). Before installation, `emulator-before-combined-ff840c4.tar` SHA-256 `4d2f265ee9216bd7fb956a6a2ae6dbf6c863ae35d4f7866bb31f56dd8676fdbc`, forward tables empty. Wi-Fi and mobile data disabled and no default network verified before cold launch. Previously cached home, profile, chat list, subject chat, QR viewer, and subject reentry were opened (`combined-ff840c4-offline-*.png`); screenshots after waits do not establish first-frame speed. Offline profile lacked avatar, chat/file/task cards and composer differ, tabs compress, so offline visual parity remains unmet. Actual online prewarm, online refresh and push were not exercised. Stopped while offline; post-check archive `emulator-after-combined-ff840c4.tar` SHA-256 `5ffa417433287a142979b4a47795590f6dd56d0701a727a89a3c93bae8530aa5` had all four forward tables empty. Reinstalled normal f378d1f then restored network and launched; archive recovery not tested. This is not a production release approval.

Read-only production contract check: `public.get_team_assignments(uuid)` currently executes as SECURITY DEFINER owned by a bypass-RLS role, grants EXECUTE to anon and authenticated, and its body filters only on supplied team_id, without checking caller membership (auth.uid appears solely in the completed-by-me subquery). Thus its response alone cannot authorize a new offline task snapshot. No function or privilege was changed. A local compatibility/security fix is being prepared; verify active membership semantics and service/teacher callers before any explicitly authorized production apply. A separate unconnected SID-scoped SQLite draft also has a reviewed owner-change-during-COMMIT gap and is not approved for display.

Production apply authorization and check, 2026-11-06: `request_user_input_async` question item call_516eb75040a54b3fa461b81e7c160797 explicitly described a one-function `get_team_assignments` migration, direct `team_members` requirement, loss of access for teachers without a row and service calls without UID, and rollback reopening the vulnerability. The user selected exactly «Применить защиту». Immediately before apply, read-only live fingerprint was `c278bc64bdcd0c88e849580c52d346e0`, owner postgres, 5 ACL entries, anon/authenticated/service_role execute true, matching the reviewed guard. Supabase apply_migration for project `gwdanmwluhrcfxbnplwd`, name `restrict_team_assignments_to_members`, returned success; migration history reports server version `20261106145137` (different from the local draft filename version). Post-apply fingerprint `a73b8a9df330d6fdf767439f95901039`; anon execute false, authenticated and service_role execute true; UID and membership predicates present. A rollback-only read test with a live team/member fixture asserted member row count matches direct source, synthetic nonmember returns zero, and UID-less call returns zero; no user identifiers or rows were emitted. This is not an end-to-end app or external-service compatibility test. No other production function, Edge deployment or data import was applied. Rollback of this change would re-enable the vulnerability and requires its own conscious decision.

Exact authorization receipt available in this execution context: on 2026-11-06, `functions.request_user_input_async` was called with question: «Нашёл риск в основной базе: функция заданий доступна без проверки членства. Подготовил и локально проверил защитную миграцию для одного `get_team_assignments`. Разрешаете применить её к основной базе? После изменения задания увидят только пользователи с записью в `team_members`; преподаватели без такой записи и сервисные вызовы без UID потеряют доступ. Откат вернёт уязвимость.» Options were «Применить защиту» and «Пока не применять». Tool response: `{"accepted":true}`. A subsequent user `send_user_message_question_reply` contained questionItemId `["request_user_input_async","call_516eb75040a54b3fa461b81e7c160797",0]` and `answer`: «Применить защиту». The message had no visible time-of-day timestamp in this execution context; none is inferred here.

Warmed PDF follow-up: normal f378d1f opened an existing forwarded PDF in its built-in viewer online (`normal-pdf-open-after.png`), producing a local 987,877-byte file and grant. After installing ce5bbfc QA offline, the same-named standalone tile did not open; it remained in chat (`pdf-cold-offline-open.png`). Subsequent read-only analysis of the project/UID/SID SQLite snapshot and SHA-derived cache keys established that the actual downloaded object corresponds to a source message dated 2026-06-08 10:30:22 UTC; the visible standalone file dated 2026-06-21 11:56:32 UTC is a different object key, and another same-named file is different as well. The older saved attachment metadata lacks `deletion_verified`. Matching by name or size would be unsafe. Offline forward content at that time was flattened to noninteractive text, so actual offline opening of the downloaded forwarded object remains unverified. Later 509701a offline screenshot showed the sender name rather than the prior fallback «Студент» for this saved view, but the forwarded files were still flattened; tapping the standalone different object showed «Локальная копия недоступна». No image was uploaded or message sent. Normal 509701a was restored with `adb install -r` after force-stop; post-test archive `emulator-after-combined-509701a.tar` SHA-256 `916416313e95589799669ac082bf09f8f61957e161a34604ed93ae3b59ffaece`, all four durable forward tables empty; network restored. Archive restoration not tested.

`509701a` full tracked-source suites: default 1,112 passed / 4 skipped, six-define combined 1,114 passed / 2 skipped (`final509-default-full.log`, `final509-combined-full.log`). Normal APK SHA-256 `894b51342de486455359cf0d46e45022d68959f6e41da41405504a9b3d4ab082`; experimental six-define APK `bd64452a157b74b3e702af1e6935b1c5625ac1fa87d57bb8a28a7a07d36ddf43`. Normal APK is installed with experimental flags off; network enabled. Six-define test does not include guarded push or no-write experimental flags, and is not a production release certification.
