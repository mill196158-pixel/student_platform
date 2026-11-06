# Ordinary launch network retry: device check

Date: 2026-11-06. This checks the ordinary build's retry after a transport
failure, not offline access to protected screens.

* On emulator-5554 the installed app was force-stopped and its private data
  archived before replacement. The archive was read in full; the forwarding
  SQLite integrity check passed, all four durable queue counts were zero,
  and no legacy queue or unclassified forward markers were found. Archive:
  `design_preview/optimizer_qa/ordinary-offline-retry-preflight-20261106/app-data-before-ordinary-retry.tar`,
  SHA-256 `da81a2f3aae08b5fd79347dc4c4cc3abbb5fd28dbd14e10d672c5cd4f02e1eab`.
  Restoration from this archive has not been tested.
* Installed ordinary APK `normal-84b1d37-20261106.apk` via `adb install -r`;
  on-device SHA-256 was
  `d3ee25a3ebbaedf27d55a07e1b7ea121a8e6c0e699cc36d2456cf3e85e00eb93`.
  Rollback APK `rollback-normal-176d521-verified.apk` was retained separately.
* Wi-Fi and mobile data were disabled. Android reported `Active default
  network: none` after launch. The app eventually displayed «Нет соединения.»
  and «Повторить» (private screenshot `ordinary-retry-offline-later.png`),
  not a protected offline home screen. Immediately after disabling the network,
  Android briefly still reported an active route; the later `none` observation
  and screenshot establish the state only after that transition.
* Wi-Fi and mobile data were enabled again, a default route was observed, and
  «Повторить» was tapped. The authenticated home screen opened (private
  screenshot `ordinary-retry-online-later.png`). The app was left on home with
  the network enabled. This single run does not verify every auth error, offline
  chat, account switch, or the speed of first paint. No manual messages or new
  attachments were sent; normal online background side effects were not audited.
