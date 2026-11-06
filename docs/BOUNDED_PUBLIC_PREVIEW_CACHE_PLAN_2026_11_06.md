# Bounded cache for reproducible public previews: local-only plan

Status: **not implemented and not enabled**. No existing cache, database,
server object, draft, offline item or device data was changed by this plan.

## Observed storage boundaries

* `NewsImageDiskCache` uses a temporary directory, an entry count of 80 and a
  nominal 48 MiB default. It is also used by authenticated content, so it is
  not a safe global eviction target for this task.
* `AppImageCache` uses `flutter_cache_manager` with 200 entries and a 14-day
  stale period; these settings are not a verified byte budget.
* `ChatFileAccess` stores private files alongside durable grants and denial
  state. Project chat/home snapshots and the forward outbox are separate
  durable stores. `GlobalCache` contains draft text and attachments. None is
  eligible for this proposed eviction policy.
* `GuestPublicService.image` obtains a temporary **signed URL** from
  `guest-news-media`. The proposed whitelist excludes signed assets; an anon
  request alone does not establish that an asset is eligible for eviction.

The source review has not established an existing consumer that satisfies
the strict whitelist. A new empty cache would neither bound existing caches
nor reduce current app storage, and must not be presented as doing so.

## Eligibility and size policy

Define the initial allowlist as a closed set of audited source identifiers;
an unrecognized source, signed URL, private content, attachment, draft,
unsent item, explicitly saved offline item, or uncertain provenance is
ineligible. Do not infer public status from URL shape, absence of credentials,
directory, MIME type, age, or a server response's cacheability alone. A
consumer must be wired only after its source and reproduction semantics have
been independently reviewed.

Store a configurable byte budget in a setting owned by the new cache. Reject
negative/out-of-range limits and bound entry count, key length, encoded input,
decoded dimensions and concurrent work before allocation. Reads update LRU;
entries in active use cannot be evicted. Lowering the budget may evict only
eligible entries from the new namespace. If pinned or in-flight entries leave
insufficient space, skip the new write and report a cache miss; do not delete
anything else. Surface separate measured values for the new cache and any
other explicitly measured store; do not label a partial count as total app
storage.

## Atomicity and ownership gate

Evaluate a new, dedicated SQLite database with content and metadata in the
same transaction, rather than coordinating a separate index and file rename.
Confirm actual driver support and the maximum practical BLOB/read size on
Android and Windows. Use bounded chunks and an atomic manifest if a single
row could exceed platform cursor limits. A crash or cancellation must expose
either the previous complete entry or the new complete entry, never partial
content. Handle corruption and unknown schema by denying the cache read, not
by deleting a directory.

Before enabling any writer, demonstrate a process-wide and cross-isolate
ownership mechanism: an OS-supported lock or a database-enforced protocol
with exclusive writer ownership, owner-liveness/crash recovery and tests.
SQLite serializes transactions, but that fact alone does not establish the
lifetime of a lease held in another process. If lease safety across processes
cannot be demonstrated, keep the feature disabled. Avoid traversing arbitrary
paths and test canonical containment and Windows reparse points at every
filesystem boundary. Do not scan or import existing cache directories.

## Required verification before wiring

* Exact allowlist and unauthorized-source tests, including signed URL,
  private content, unknown provenance and a saved-offline sentinel.
* LRU read ordering, count and byte limits, resize of budget, oversize input,
  zero-space behavior and preservation of pinned/in-use entries.
* Simultaneous reads/writes, duplicate writers in processes and isolates,
  cancellation at each stage, restart and recovery after each transaction
  boundary, malformed index and schema-version rejection.
* Real SQLite persistence and reopen on Windows and Android; measure peak
  memory for bounded input and large images. Exercise system storage-full and
  cleanup failures without touching unrelated files.
* Sentinels proving that GlobalCache drafts, pending outbox, existing cached
  chat files/grants, local snapshots and server originals are unchanged.
* Independent review of the exact source classification, lifecycle, race
  behavior and consumer wiring, followed by device QA before release.
