# Team image gate: emulator preflight stopped

Date: 2026-11-06. The requested QR re-entry test of ordinary candidate
`816c4ae` was **not performed**. Its prepared APK SHA-256 was
`f8cb04192bbf8f742f3ffca0af5a58cb7e97eb390d1621b63182c9fc1f7b2331`.

The previous emulator was not attached when preflight started. The existing
`Pixel_9a` AVD was restarted without wipe/reset and appeared as emulator-5554.
Its installed `com.mill453020.studentplatform` was not the previously checked
debug build: on-device APK SHA-256 was
`45e21d6f42d5ab99b6c60086804bbb50048271938b0cf3071751d74df423bd08`,
versionCode 18, without the debuggable flag. `run-as` returned
`package not debuggable`; the attempted tar was invalid. The installed app's
private data and queue contents were not read or verified. No candidate APK
was installed and no cleanup or data reset was performed. A package force-stop
had happened before archive failure; the existing installed app was launched
again and the network was active (default network 105). It showed the guest
home «Без регистрации», not the earlier authenticated test account, as in the
private local screenshot `design_preview/optimizer_qa/pixel9a-original-restored.png`.
Normal automatic online startup side effects were not audited.

The existing rollback APKs remain separate: `normal-84b1d37-20261106.apk`
SHA-256 `d3ee25a3ebbaedf27d55a07e1b7ea121a8e6c0e699cc36d2456cf3e85e00eb93`
and `rollback-normal-176d521-verified.apk` SHA-256
`cd142f83cd23e1ccdbecc2a0d09ccdad67095ff993b14c58f5a1871aa69cfda7`.
Those APKs and older archives are not proof of a recoverable backup of the
current non-debuggable installation. No attempt was made to bypass `run-as`.

Read-only backup metadata: Android Backup Manager was disabled and `bmgr list
sets` reported no restore sets. `ALLOW_BACKUP` alone is not evidence of a
recoverable backup. The installed APK was pulled separately to
`design_preview/optimizer_qa/pixel9a-original-45e21-20261106.apk`; its local
SHA-256 matched the on-device `45e21d6f42d5ab99b6c60086804bbb50048271938b0cf3071751d74df423bd08`.
`apksigner verify --print-certs` returned the same signing-certificate SHA-256
for this APK and candidate `816c4ae`:
`5e15b2d96f7a84f0b44a8a07552ea2483e26f938ab0045b72fd3bbb03a530bc9`.
The APK copy and matching signature do not back up the private app data or
demonstrate a working rollback of those data; installation was not attempted.
