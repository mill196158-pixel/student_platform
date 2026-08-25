-- Resolve the SQL-alias/PL/pgSQL-record ambiguity discovered by the remote
-- rollback role-play without rewriting the already-applied Slice 2 migration.

begin;

do $hotfix$
declare
  v_definition text;
  v_original text;
begin
  select pg_get_functiondef(
    'private.group_recognition_refresh_preview_v2(uuid)'::regprocedure
  )
  into v_definition;

  if v_definition is null then
    raise exception 'group_recognition_refresh_function_missing';
  end if;
  if position('#variable_conflict' in v_definition) > 0 then
    raise exception 'group_recognition_refresh_conflict_policy_already_set';
  end if;

  v_original := v_definition;
  v_definition := replace(
    v_definition,
    E'AS $function$\ndeclare',
    E'AS $function$\n#variable_conflict use_column\ndeclare'
  );
  if v_definition = v_original then
    raise exception 'group_recognition_refresh_header_not_recognized';
  end if;

  execute v_definition;
end
$hotfix$;

revoke all on function private.group_recognition_refresh_preview_v2(uuid)
  from public, anon, authenticated;
grant execute on function private.group_recognition_refresh_preview_v2(uuid)
  to service_role;

commit;
