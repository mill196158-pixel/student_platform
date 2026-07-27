# CURRENT_TASK

* Status: GROUP_SPACE_ORGANIZER_ADMIN_UI — awaiting remote apply (owner-gated)
* Branch: `refactor/chat-tab`
* Codex thread: `019fa373-81f2-7962-a8c9-81d86cb62311`
* Focus: Stage 13.2 organizer Admin UX in Students (13.5)

## Organizer model (authoritative)

1. Organizer = active enrollment in group-space membership **and** one of:
   - durable `group_space_organizer_grants(source='admin')` via `set_group_space_organizer`;
   - live `team_members.role in ('starosta','owner')` on an **active** subject-team of the same `group_id`.
2. Active subject-team gate: `private.is_active_subject_team_for_group`.
3. Admin UI shows source labels; revoke removes only explicit grant (natural starosta remains).
4. `users.role` never ongoing auth; admin RBAC ≠ organizer identity.

## Admin UI path

**Студенты** (`/academic/students`) → выбрать группу (chip) → диалог **Организаторы пространства группы**.
Manage buttons only when `groups.write` | `students.write` | `terms.manage`.
RPCs: `admin_list_group_space_organizer_state`, `admin_set_group_space_organizer`.
Migration: `20260727182537_stage13_2_admin_group_organizer.sql` (+ `20260727140000_stage13_2_group_space.sql`).

## Validation

* Admin tests: `flutter test test/students_admin_stage13_5_test.dart`
* Local DB: `bash scripts/local_preflight_stage13.sh`

## Next owner actions

1. Remote apply migrations in checklist order (incl. organizer admin RPC).
2. Smoke Admin organizer dialog after apply.
3. Edge deploy + physical Android/iPhone checklist.

## Constraints

* No force-push / no remote migrate-from-agent without permission
