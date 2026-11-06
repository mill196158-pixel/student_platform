-- Prepared rollback. Restores the original vulnerable functions and
-- PUBLIC/anon grants. Remote execution requires separate owner approval.
begin;
do $guard$
declare
  entry record;
  function_oid oid;
  definition text;
  admission text;
  restored text;
begin
  for entry in select * from (values
    ('public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)',
     '00ec8efaccb63d6d1fff84704b46d2d0', 'f51be1f52d3ad8ba4b3b539a878f93bf', 'v_author_id'),
    ('public.send_chat_message_with_files(uuid,text,text,uuid[])',
     '338bd0e898b8f70b6438dd3787bd7b9c', '00c0ad8bc07aa3f12792c2af951bbb8e', 'v_user_id')
  ) as v(signature, protected_fingerprint, original_fingerprint, actor) loop
    function_oid := pg_catalog.to_regprocedure(entry.signature);
    if function_oid is null then raise exception 'protected team send function missing'; end if;
    definition := pg_catalog.replace(pg_catalog.pg_get_functiondef(function_oid), pg_catalog.chr(13), '');
    if pg_catalog.md5(definition) <> entry.protected_fingerprint then
      raise exception 'protected team send definition differs';
    end if;
    if not exists (
      select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_roles owner_role on owner_role.oid=p.proowner
      where p.oid=function_oid and p.prosecdef and owner_role.rolname='postgres'
        and (select count(*) from pg_catalog.aclexplode(p.proacl) a
          where a.privilege_type='EXECUTE' and a.grantor=p.proowner and not a.is_grantable
          and a.grantee in ('postgres'::pg_catalog.regrole,'authenticated'::pg_catalog.regrole,
                            'service_role'::pg_catalog.regrole)) = 3
        and (select count(*) from pg_catalog.aclexplode(p.proacl)) = 3
    ) then raise exception 'protected team send owner or grants differ'; end if;
    admission := pg_catalog.format(E'  PERFORM 1 FROM public.team_members tm\n    WHERE tm.team_id = p_team_id AND tm.user_id = %I\n    FOR KEY SHARE;\n  IF NOT FOUND THEN\n    RAISE EXCEPTION ''forbidden'' USING ERRCODE = ''42501'';\n  END IF;\n\n', entry.actor);
    restored := pg_catalog.replace(definition, admission, '');
    if pg_catalog.md5(restored) <> entry.original_fingerprint then
      raise exception 'original team send definition cannot be reconstructed';
    end if;
    execute restored;
  end loop;
end
$guard$;
grant execute on function public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid) to public, anon, authenticated, service_role;
grant execute on function public.send_chat_message_with_files(uuid,text,text,uuid[]) to public, anon, authenticated, service_role;
commit;
