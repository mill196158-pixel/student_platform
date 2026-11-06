# Receipt isolate: restricted offline QA, 2026-11-06

This is a debug-only experiment, disabled by default. It is not approved for production, online revalidation, or as proof of equivalent behavior under all cross-process interleavings. No measured improvement is established.

## Device observations

On one emulator and one previously saved chat image, the `QA_RECEIPT_ISOLATE` build displayed the image with network disabled. Three completed probe intervals in one cold run were 102, 6 and 43 ms (`design_preview/optimizer_qa/receipt-isolate-cold-stages.log`). The sequential legacy control, also offline, showed 145 and 23 ms on cold entry and 43/47 and 88/164 ms on two subsequent entries (`receipt-legacy-control-stages.log`). Some starts have no matching completion: their cause is not established. The samples are few, the cold and warm runs differ, and individual operations cannot be paired by object. Debug instrumentation and emulator scheduling affect timings. These numbers do not establish a speedup or instant image display.

Both tests used previously saved content; no message or new file was sent. Network was disabled before the control launch. The device checks do not prove absence of every automatic write by every SDK component. The archives were read and hashed, not restored; restore has not been tested.

## Evidence and device restoration

- Isolate APK SHA-256: `134f39cbcc400e6a6b1754067d8f8d61ab683289bc2efefef8f805b615ecc02e`.
- Isolate preflight archive SHA-256: `0e821da84fe6c19d9e7e9ba76939c16558a92651853bbe6bfaa3ccf4d4f2c6eb`; postflight: `18986aa7850e840baa88e0b75ff7edd7bbb93dffa5d21cabbe1ac25940287768`.
- Legacy control APK SHA-256: `c9545b1f718fe4b3eac92b2af9482620452daefe70bf90213ff0a179cda15323`; preflight archive: `46d00b6a4e6f2584d2355c8baf6994d5c8439c5cfd50b1c31682db3e13a4870f`; independently repeated postflight archive: `a72c3015157f2bb43882894f8d2dbb0c6ff82c5d22b2d43bd213a328e0fd76bd`. Postflight durable and legacy forward queues and unclassified forward sentinels were zero.
- Normal 176d521 restored using `install -r`; on-device APK SHA-256 `cd142f83cd23e1ccdbecc2a0d09ccdad67095ff993b14c58f5a1871aa69cfda7`. Default network active and home screen visually verified. Evidence: `design_preview/optimizer_qa/legacy-control-restored-home2.png` (contains private UI data; do not publish).

## Exact reviewed experimental snapshot

The four-file reviewed snapshot and its full hashes are retained at `design_preview/optimizer_qa/receipt-isolate-reviewed-20261106/manifest.json`. Its `chat_file_access.dart` SHA-256 is `13af94daa82953851c90054a8c5007812b7713f2cb68bbb6afe7409b00523d7c`. The current original-tree version has additional separately reviewed legacy control timing labels and SHA-256 `2747fb7c51d2046779ebc63cb775256fbef1240de49a99508ceaa1e55f371934`. The other three snapshot file hashes remain unchanged. The whole working tree was not frozen at either build: do not infer an exact commit from the APK.

The control uses existing seven QA defines plus `QA_REENTRY_TIMING=true`, without `QA_RECEIPT_ISOLATE`. The isolate variant additionally enables `QA_RECEIPT_ISOLATE=true`. Both require debug mode. The probe preserves ordered marker checks; a pending marker falls back to the existing path under the same owner queue. There is no cached allow. This is not an interprocess lock.

Targeted isolate tests: six passed with the flag and linked default-off test passed; targeted control tests: seven passed. Independent review approved only a restricted offline device timing run, not release or all external-process interleavings. The default remains unchanged.
