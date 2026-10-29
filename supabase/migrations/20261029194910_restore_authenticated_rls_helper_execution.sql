-- RLS expressions execute as the caller, even when their predicates are private.
-- These read-only predicates derive identity from auth.uid(); policies stay intact.
REVOKE ALL ON FUNCTION private.is_group_space_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_group_space_member(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.is_group_space_organizer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_group_space_organizer(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.is_active_team_member(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_active_team_member(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.can_manage_team_topics(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_manage_team_topics(uuid) TO authenticated;
REVOKE ALL ON FUNCTION private.can_manage_team_collections(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_manage_team_collections(uuid) TO authenticated;
