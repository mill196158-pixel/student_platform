# Push navigation: QA limitations (6 November 2026)

The guarded QA build does **not** restore online push navigation without a
notification ID or the seven topic/collection group-action links. It must not
be presented as a complete fix. The normal legacy mode is separate.

Read-only inspection of the deployed dispatcher and delivery-gate definitions
showed that the emitted notification ID comes from the outbox foreign key,
not its top-level payload ID. The current outbox snapshot contained 131 rows
whose foreign key was null; all had a top-level payload ID, none had a nested
data ID, and none of those IDs matched an extant recipient notification. This
is a historical snapshot, not a prediction about future push delivery. Six
group-action outbox rows were marked sent; that status does not prove device
delivery. No notifications were sent and no production data was changed.

The current guarded opener requires a non-empty notification ID and verifies
the current recipient before navigation. Without one it returns without
opening. Guarded routing explicitly returns for topic/collection action types.
Removing these guards would accept a delayed push from an earlier account;
incoming titles, bodies and destination IDs are not proof of its owner.

A compatible client-only direction is to treat a payload chat ID solely as a
lookup hint, query `get_my_chat_summaries` using the exact current session,
require one matching current-access row, and use peer/team data from that row
instead of the incoming payload. This checks present access; it cannot prove
who received the original notification. Missing, ambiguous or failed lookups
must not open a private target. Exact session/client identity and the barrier
must be checked after each await, and the target route closed on revocation.

This alone is insufficient: `DirectChatScreen`, `TeamDetailsScreen` and the
group-action details route have asynchronous operations not fully tracked by
the online barrier. Removing the route on close does not drain those child
operations. The cached-only variants require a cache-only permit, expose only
previously saved history, and do not preserve normal online chat or group
action functionality. Issuing an artificial permit or changing the entire
app's mode would not be a safe substitute.

Before enabling targeted navigation, adapt the target screens and their
repositories so all session-bound operations are tracked and fenced through
route disposal and session/barrier changes; verify group-action membership and
entity access under the current session, and avoid using untrusted payload
text. Add synthetic tests for no-ID, duplicate/missing targets, 403/network
failure, late responses, account and same-user session changes, barrier close
while a child operation runs, route disposal, and no mark-read or mutation.
Then test real device navigation without sending or changing user data.

The experimental `guarded_push_target.dart` and its test are unconnected and
are excluded from the QA checkpoint. They do not fix this user-facing issue.
