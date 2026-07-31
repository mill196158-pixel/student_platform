-- Stage 13.8 hardening: lock search_path on private.stage13_8_lifecycle.
-- Advisor: function_search_path_mutable.
-- Function is IMMUTABLE SQL helper (not SECURITY DEFINER, not a trigger, not a public RPC).
-- Body uses only input parameters; no table reads/writes. Product data unchanged.

create or replace function private.stage13_8_lifecycle(
  p_is_current boolean,
  p_term_sequence integer,
  p_current_sequence integer
)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_is_current, false) then 'active'
    when p_current_sequence is not null and p_term_sequence > p_current_sequence then 'planned'
    else 'completed'
  end;
$$;

revoke all on function private.stage13_8_lifecycle(boolean, integer, integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Documentation note (advisors INFO: rls_enabled_no_policy on
-- public.group_collection_secrets): intentional.
-- - FORCE RLS enabled
-- - no direct grants to anon/authenticated (RPC-only access)
-- - payment requisites exposed only via SECURITY DEFINER RPCs with
--   organizer/owner checks (list_group_collections redacts; secrets table
--   has no client policies by design)
-- ---------------------------------------------------------------------------
comment on table public.group_collection_secrets is
  'Sensitive payment requisites. FORCE RLS; no client policies/grants. Access only via SECURITY DEFINER RPCs with organizer/owner checks.';
