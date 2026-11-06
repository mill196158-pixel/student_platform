-- LOCAL REVIEW ONLY. Do not apply remotely without explicit owner approval.
-- Narrow scope: preserve the existing RPC bodies and change only membership
-- admission and execute grants. File linking behavior remains out of scope.
begin;
do $guard$
declare
  entry record;
  function_oid oid;
  definition text;
  marker constant text := '  SELECT id INTO v_chat_id';
  admission text;
begin
  if pg_catalog.pg_has_role('anon', 'authenticated', 'MEMBER')
     or pg_catalog.has_schema_privilege('anon', 'public', 'CREATE')
     or pg_catalog.has_schema_privilege('authenticated', 'public', 'CREATE')
     or pg_catalog.has_schema_privilege('public', 'public', 'CREATE') then
    raise exception 'unexpected role or schema privileges';
  end if;
  if (select count(*) from pg_catalog.pg_trigger t
      join pg_catalog.pg_proc p on p.oid=t.tgfoid
      join pg_catalog.pg_roles r on r.oid=p.proowner
      where not t.tgisinternal and t.tgenabled='O' and p.prosecdef and r.rolname='postgres'
        and (select count(*) from pg_catalog.aclexplode(p.proacl) a
          where a.privilege_type='EXECUTE' and a.grantor=p.proowner and not a.is_grantable
            and a.grantee='postgres'::pg_catalog.regrole)=1
        and (select count(*) from pg_catalog.aclexplode(p.proacl))=1
        and ((t.tgrelid='public.chat_files'::pg_catalog.regclass
              and t.tgname='guard_chat_file_message_binding'
              and pg_catalog.md5(pg_catalog.replace(pg_catalog.pg_get_triggerdef(t.oid),pg_catalog.chr(13),''))='a593b3a961329b7568ff304f380c04be'
              and pg_catalog.md5(pg_catalog.replace(pg_catalog.pg_get_functiondef(p.oid),pg_catalog.chr(13),''))='b4f972aca12fa763fbd614fdb40974b6')
          or (t.tgrelid='public.messages'::pg_catalog.regclass
              and t.tgname='guard_message_file'
              and pg_catalog.md5(pg_catalog.replace(pg_catalog.pg_get_triggerdef(t.oid),pg_catalog.chr(13),''))='e8737afd80fe696aa2dc1f241926d9e1'
              and pg_catalog.md5(pg_catalog.replace(pg_catalog.pg_get_functiondef(p.oid),pg_catalog.chr(13),''))='a5ba1dadda889a0d64fe692e3b1816be'))) <> 2 then
    raise exception 'required live file guards differ';
  end if;
  for entry in select * from (values
    ('public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)',
     'f51be1f52d3ad8ba4b3b539a878f93bf', 'v_author_id'),
    ('public.send_chat_message_with_files(uuid,text,text,uuid[])',
     '00c0ad8bc07aa3f12792c2af951bbb8e', 'v_user_id')
  ) as v(signature, fingerprint, actor) loop
    function_oid := pg_catalog.to_regprocedure(entry.signature);
    if function_oid is null then
      raise exception 'team send function missing';
    end if;
    definition := pg_catalog.replace(pg_catalog.pg_get_functiondef(function_oid), pg_catalog.chr(13), '');
    if pg_catalog.md5(definition) <> entry.fingerprint then
      raise exception 'team send definition differs from audited snapshot';
    end if;
    if not exists (
      select 1 from pg_catalog.pg_proc p
      join pg_catalog.pg_roles owner_role on owner_role.oid=p.proowner
      where p.oid=function_oid and p.prosecdef and owner_role.rolname='postgres'
        and (select count(*) from pg_catalog.aclexplode(p.proacl) a
          where a.privilege_type='EXECUTE' and a.grantor=p.proowner and not a.is_grantable
          and a.grantee in (0, 'postgres'::pg_catalog.regrole, 'anon'::pg_catalog.regrole,
                            'authenticated'::pg_catalog.regrole, 'service_role'::pg_catalog.regrole)) = 5
        and (select count(*) from pg_catalog.aclexplode(p.proacl)) = 5
    ) then
      raise exception 'team send owner or grants differ from audited snapshot';
    end if;
    if pg_catalog.strpos(definition, marker)=0
       or pg_catalog.strpos(pg_catalog.substr(definition, pg_catalog.strpos(definition, marker)+pg_catalog.length(marker)), marker)>0 then
      raise exception 'team send insertion point differs from audited snapshot';
    end if;
    admission := pg_catalog.format(E'  PERFORM 1 FROM public.team_members tm\n    WHERE tm.team_id = p_team_id AND tm.user_id = %I\n    FOR KEY SHARE;\n  IF NOT FOUND THEN\n    RAISE EXCEPTION ''forbidden'' USING ERRCODE = ''42501'';\n  END IF;\n\n', entry.actor);
    execute pg_catalog.replace(definition, marker, admission || marker);
  end loop;
end
$guard$;

revoke all on function public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid) from public, anon;
revoke all on function public.send_chat_message_with_files(uuid,text,text,uuid[]) from public, anon;
grant execute on function public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid) to authenticated, service_role;
grant execute on function public.send_chat_message_with_files(uuid,text,text,uuid[]) to authenticated, service_role;
do $verify$
declare function_oid oid;
begin
  for function_oid in select p.oid from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.oid in (
      'public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid)'::pg_catalog.regprocedure,
      'public.send_chat_message_with_files(uuid,text,text,uuid[])'::pg_catalog.regprocedure
    ) loop
    if pg_catalog.has_function_privilege('anon',function_oid,'EXECUTE')
       or not pg_catalog.has_function_privilege('authenticated',function_oid,'EXECUTE')
       or not pg_catalog.has_function_privilege('service_role',function_oid,'EXECUTE') then
      raise exception 'unexpected effective team send privileges';
    end if;
  end loop;
end
$verify$;
commit;
