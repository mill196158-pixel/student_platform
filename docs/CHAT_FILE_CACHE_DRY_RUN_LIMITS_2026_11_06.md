# Chat-file cache accounting: safety boundary

Status: **not implemented; not enabled**. No runtime audit or cleanup is
provided by this document. No app files, draft data, offline copies, server
objects, backup settings or device data were removed or changed.

The `authorized_chat_files/<uid>` tree can contain cached payloads, durable
grant, denial and pending markers, and `forward_*` directories containing
temporary files still needed by a draft or operation. A digest-shaped name
or a cached payload is not evidence that an item can be safely evicted.

A local experimental read-only scan counted immediate digest-named files
without listing content and returned zero reclaimable bytes. It checked the
current client, session identity, uid, session id and generation around
asynchronous work; synthetic tests checked preservation of draft and external
sentinels and rejected an owner A-to-B-to-A transition. This experiment was
removed after independent review and must not be included in a build.

The remaining blocker is filesystem identity: checking that a path is not a
link and then calling Dart `File.stat()` permits the path to be replaced by a
link between those operations. The resulting size can refer to an external
file. Rechecking the path afterward cannot rule out an ABA replacement.
Concurrent changes can also make a directory scan incomplete. Therefore the
scan cannot be reported as accurate owner-scoped accounting solely on those
checks, even when it performs no deletion.

Before implementation, demonstrate platform-specific no-follow handles with
stable file identity, directory containment and Windows reparse-point handling
on Android and Windows; define how all app writers and other processes are
coordinated, including interrupted scans. When proof is unavailable, return
unavailable rather than a partial or misleading number. Keep results limited
to this tree, never label them total application size, and retain zero
reclaimable bytes until drafts, in-flight operations, explicitly offline items
and durable access markers can be distinguished safely. Require independent
review and synthetic sentinel/race tests before any UI or eviction is enabled.
