# CURRENT_TASK

* Status: ORGANIZER_AUTHORITY_FIXED — awaiting remote apply (owner-gated)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Focus: Stage 13.2 group-space organizer source (not `users.role`)

## Organizer model (authoritative)

1. Organizer = active enrollment in group-space membership **and** one of:
   - durable `group_space_organizer_grants(source='admin')` via `set_group_space_organizer`;
   - live `team_members.role in ('starosta','owner')` on an **active** subject-team of the same `group_id`.
2. Active subject-team gate: `private.is_active_subject_team_for_group` — offering `status='active'` (or current term when no offering) and `team_main` not academically archived.
3. Server sync (`refresh_group_space_organizer_grants` + subject-team trigger) assigns/revokes `subject_team` grants; losing starosta or archiving offering revokes organizer.
4. `users.role` is legacy only — one-time migration backfill to admin grants; never ongoing auth.
5. `admin_role_assignments` is admin RBAC, not organizer identity (`content_editor` cannot set organizer).
6. Students cannot gain organizer by changing their own profile (`users` self-update blocked / role ignored).

## First manual organizer after remote apply

RPC (SQL / Supabase): `select public.set_group_space_organizer('<group_id>'::uuid, '<user_id>'::uuid, true);`
Caller must pass `private.is_group_space_admin()` (`groups.write` | `students.write` | `terms.manage`). No dedicated Admin UI screen yet.

## Validation

* Local: `bash scripts/local_preflight_stage13.sh` → `PREFLIGHT_OK`
* Migration (not applied remotely): `20260727140000_stage13_2_group_space.sql`

## Next owner actions

1. Remote apply migrations one-by-one (start with news archive if still pending, then Stage 13.2–13.6).
2. After 13.2 apply: assign first organizer via `set_group_space_organizer` (or ensure active subject-team starosta).
3. Edge deploy + physical Android/iPhone checklist.

## Constraints

* No force-push / no remote migrate-from-agent without permission
