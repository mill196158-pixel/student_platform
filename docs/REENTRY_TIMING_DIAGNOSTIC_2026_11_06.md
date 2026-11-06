# Re-entry timing diagnostic — 2026-11-06

This is one Android emulator observation on an already opened QR image, using a debug build with instrumentation. It is not a release-performance measurement, a claim about all frames, or evidence that offline server revocations or multiple processes are handled.

## Scope and files

The APK was built in `C:\student_platform` from the working tree currently at `c697ec3521a7b0d01f03ba3e6f71003ff045b031` plus diagnostic edits; HEAD was not recorded at the instant of compilation and a whole-tree freeze is not claimed. It used `SQLITE_POLICY_QA`, `OFFLINE_UI_QA`, `FORWARD_DURABLE_ANDROID_QA`, `CHAT_REENTRY_GATE_QA`, `QA_ROTATION_NAVIGATION_EXPERIMENT`, `QA_LOCAL_IMAGE_PREWARM`, `QA_NO_AUTOMATIC_WRITES`, and `QA_REENTRY_TIMING`, all set true. Diagnostic timestamps and integer trace IDs contain no account, file, URL, or token fields. No manual message or new file was sent. `QA_NO_AUTOMATIC_WRITES` is limited and does not prove that every SDK/background path makes no writes.

Frozen diagnostic file SHA-256:

- `lib/src/services/chat_file_access.dart`: `629474a33bd1a1c1f9822cd2f9cead8179b0631fb62ec3629db5c27b8a541699`
- `lib/src/ui/learning/widgets/authorized_file_image.dart`: `424067476056c6a0b8f6db8805d95ae81798a68ca04527ee01a9612ab38db230`
- `lib/src/ui/learning/widgets/reentry_image_gate.dart`: `7ce74c2edeb67c28518e1f837af4f758cdde2606cf296b18ce61869766e66b19`
- `lib/src/ui/learning/widgets/qa_reentry_timing.dart`: `75d8f6ce45f722caf2b6bf2cd6c273399aa7440aa459bd74b4883fb3df781531`

Debug APK SHA-256: `7088a9fcdf36d611e7c930068c1cc8e8e97bef2fe4aea72be31d801706c5aed0`. Analyzer found no issues; the focused gate suite passed 5/5. Instrumentation received scoped independent review for diagnostic use.

## Observed repeated entry

Monotonic milliseconds, from the locally saved sanitized `design_preview/optimizer_qa/numeric-reentry-stages.log`:

- Gate initialized at 28661, with the snapshot already ready. Provider 14 waited for the owner file queue from 28798 to 28914 (116 ms); its path was available at 28915 and marker check finished at 29270 (355 ms). Its key was ready at 29273.
- Image-finished was logged at 29319 and gate reveal at 29330, 669 ms after gate initialization. Those gate/image events do not have provider trace IDs, so their exact association with provider 14 is inferred from order, not proven.
- Provider 15 was also active; its marker check finished at 29790, after reveal. Thus this single run does not establish that deduplicating the two requests would shorten the critical path. Background resolve logs are unnumbered. No file GET appeared in this repeat-entry slice; absence of a logged event is limited to these instrumented paths.

One earlier, separately instrumented repeat reached the gate timeout before authorization finished; its stages are in `design_preview/optimizer_qa/original-reentry-timing-stages.log`. The timings vary with emulator/debug load. There is no verified fix or claim of instantaneous re-entry.

## Device and recovery

The app was force-stopped before installation. Full-read preflight archive: `design_preview/optimizer_qa/numeric-timing-preflight-20261106/app-data-before-numeric-timing.tar`, SHA-256 `c70c81678caea1369d407cf243f2b1baaf6e0dda0edcaa60c468621b59dc5de2`. SQLite integrity passed; durable and legacy forwarding queues and unclassified forward markers were empty. Installed only with `adb install -r`.

The postflight archive `design_preview/optimizer_qa/numeric-timing-postflight-20261106/app-data-after-numeric-timing.tar` was fully read, SHA-256 `015b662d55521d5dbb622f935919cbdcdb52ef3dcaf8630450885e1516f43937`, with those queue counts still zero. Archive restore was not tested.

Normal `176d521` was restored with `adb install -r`; on-device APK SHA-256 `cd142f83cd23e1ccdbecc2a0d09ccdad67095ff993b14c58f5a1871aa69cfda7`, active default network 135 and home visible in `design_preview/optimizer_qa/numeric-timing-restore2.png`. Screenshots and video under the QA directory may contain private chat content and should remain local.
