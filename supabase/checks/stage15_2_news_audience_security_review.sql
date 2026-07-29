-- Stage 15.2 — news audience security review (assertive DO blocks).
-- Run AFTER local apply of 20260729140000_stage15_2_news_audience_extension.sql.
-- Never --linked / never production.

do $$
begin
  if exists (
    select 1
    from (
      values ('news_audience_groups'), ('news_audience_users')
    ) as t(table_name)
    left join pg_class c
      on c.relname = t.table_name
     and c.relnamespace = 'public'::regnamespace
    where c.oid is null
       or not c.relrowsecurity
       or not c.relforcerowsecurity
  ) then
    raise exception 'stage15_2: junction tables missing FORCE RLS';
  end if;

  if exists (
    select 1
    from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in ('news_audience_groups', 'news_audience_users')
      and grantee in ('anon', 'authenticated', 'PUBLIC', 'public')
  ) then
    raise exception 'stage15_2: client DML grants on junctions';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('private', 'public')
      and p.proname in (
        'news_audience_matches',
        'news_post_deliverable_to_user',
        'admin_set_news_audience',
        'admin_preview_news_audience',
        'admin_publish_news',
        'get_my_published_news',
        'mark_news_seen'
      )
      and (
        p.prosecdef is not true
        or coalesce(array_to_string(p.proconfig, ','), '') not like '%search_path%'
      )
  ) then
    raise exception 'stage15_2: SECURITY DEFINER/search_path contract broken';
  end if;

  if exists (
    select 1
    from (
      values ('news_audience_groups'), ('news_audience_users')
    ) as t(relname)
    join pg_class c
      on c.relname = t.relname
     and c.relnamespace = 'public'::regnamespace
    where not exists (
      select 1
      from pg_trigger tr
      where tr.tgrelid = c.oid
        and not tr.tgisinternal
        and tr.tgname like '%audience%invariant%'
        and (tr.tgtype & 8) = 8
    )
  ) then
    raise exception 'stage15_2: missing deferred DELETE audience invariant triggers';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
    where n.nspname = 'public'
      and p.proname in (
        'admin_set_news_audience',
        'admin_preview_news_audience',
        'get_my_published_news',
        'mark_news_seen'
      )
      and acl.privilege_type = 'EXECUTE'
      and (
        acl.grantee = 0 -- PUBLIC
        or acl.grantee = 'anon'::regrole
      )
  ) then
    raise exception 'stage15_2: PUBLIC/anon EXECUTE on audience RPCs';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'admin_set_news_audience',
        'admin_preview_news_audience',
        'get_my_published_news',
        'mark_news_seen'
      )
      and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) then
    raise exception 'stage15_2: authenticated missing EXECUTE on audience RPCs';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_my_published_news', 'mark_news_seen')
      and pg_get_functiondef(p.oid) not ilike '%news_audience_matches%'
      and pg_get_functiondef(p.oid) not ilike '%news_post_deliverable_to_user%'
  ) then
    raise exception 'stage15_2: student RPCs do not use shared audience resolver';
  end if;

  raise notice 'stage15_2 security review PASSED';
end;
$$;
