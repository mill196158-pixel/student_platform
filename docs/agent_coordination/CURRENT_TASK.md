# CURRENT_TASK

* Status: **STAGE_13_11_1_DONE** / Codex **APPROVE** (9/9)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Remote project: `gwdanmwluhrcfxbnplwd`
* PR: https://github.com/mill196158-pixel/student_platform/pull/1
* Remote migration (unchanged): `20260728140108_stage13_11_membership_capabilities_ux`

## Stage 13.11.1 — keyboard focus hotfix

* Forms «Выбор темы» / «Скинуться»: keyboard opened then immediately closed
* Root cause: `KeyboardDismissScope` dismissed on programmatic `ScrollUpdateNotification` (`|scrollDelta| > 2`) from keyboard inset re-layout
* Fix: scroll dismiss only when `dragDetails != null`; keep translucent `onTap` outside dismiss
* Tests: `test/keyboard_dismiss_scope_stage13_11_1_test.dart`
* No migration / no remote apply / no Edge

## Residuals (owner)

* **PHYSICAL OCR SMOKE REQUIRED** — Android/iPhone
* **TWO-DEVICE TOPIC RACE REQUIRED**
* **CONTROLLED PUSH REQUIRED** — one real group-action notification path on device
* **REAL XLSX REQUIRED** — production imports (dry-run first; no fixtures)
* Physical device smoke for chat forms after 13.11.1 (emulator/simulator builds covered in closeout)

## Constraints

* No force-push
* No teacher-media deploy until explicitly requested
* Do not create autumn 2026 / do not flip current term without explicit owner OK
