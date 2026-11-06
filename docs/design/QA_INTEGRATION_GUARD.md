# Android integration test preflight

This is a read-only preflight for a future, separate QA emulator. It never runs
Flutter, starts an emulator, installs/uninstalls an app, clears storage, or changes
a device. It defaults to refusal. The current production configuration uses
`com.mill453020.studentplatform`, so this repository cannot pass until a genuinely
separate QA build and isolated AVD have been prepared and reviewed.

The guard requires an exact running `emulator-NNNN` serial and a matching dedicated
`Codex_QA_*` AVD name; a literal, distinct `com.mill453020.studentplatform.qa.*`
Gradle namespace and applicationId; and an actual APK whose package as reported
by `aapt dump badging` is the same QA ID. It checks the explicitly supplied
current Android user, enumerates every returned user/profile, and refuses if the
production package is present (including entries shown by `pm list packages -u`)
in any of them. It requires the explicit `--no-uninstall` declaration. Unsupported
or ambiguous configurations are refused. To reject a later dynamic override,
each identifier must occur exactly once in the provided Gradle file; additional
mentions, including comments and qualified setters, fail closed. This is not a
complete analysis of applied Gradle plugins, imported scripts, reflection or code
in other files; the checked APK remains a separate point-in-time artifact.

Run unit tests without a device:

```powershell
python -m unittest discover -s test -p test_qa_android_guard.py -v
```

When a dedicated QA environment already exists, invoke the preflight with absolute
paths to `adb.exe`, `aapt.exe`, the exact built QA APK and the QA Gradle file,
plus `--serial`, `--avd`, `--user`, `--qa-package` and `--no-uninstall`.
Never infer or reuse a serial. The emulator must have independently verified,
disjoint data and image paths; its name alone cannot establish isolation.

**A PASS is only a point-in-time read-only check, not permission to run Flutter.**
It does not bind a subsequent Flutter process to the inspected APK; `flutter test`
may rebuild a different artifact. It cannot prevent a device/user switch after
checking, prove snapshot path isolation, prevent a test from modifying app data,
or enforce `--no-uninstall` on a later command. A future runner must close those
gaps, verify the actual final artifact and exact user immediately before any
operation, and pass `--no-uninstall` to Flutter itself. The flag keeps the tested
package installed; it does not prevent tests from changing its data.

During the November 2026 incident, a test build changed `applicationId` but kept
the main app's `namespace`. Flutter selected that namespace before the QA APK was
built and its default integration-test cleanup removed the main package. The
subsequent attempt to open a different package was mistakenly reported as recovery.
Only one person should control the emulator at a time, and the actual foreground
package and screen must be verified after a launch.

Following the emulator/test incident, do not treat an APK as a backup: it does not
contain app-private data, login state or emulator disk/snapshot state. Check the
actual foreground app and Android profile separately; this preflight does not do
so. Do not delete or overwrite saved AVDs, disk images, backups or snapshots.
Opening a copied snapshot on the same host is unsafe until embedded absolute paths
and storage isolation are independently verified. If recovery is needed, preserve
originals and work from verified copies in a separate environment.
