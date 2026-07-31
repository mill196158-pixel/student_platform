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

-- Structural + data invariants that the block above does not cover.
do $$
begin
  -- service_role keeps the DML the clients must not have.
  if exists (
    select 1
    from (values ('news_audience_groups'), ('news_audience_users')) as t(table_name)
    where (
      select count(distinct g.privilege_type)
      from information_schema.role_table_grants g
      where g.table_schema = 'public'
        and g.table_name = t.table_name
        and g.grantee = 'service_role'
        and g.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
    ) < 4
  ) then
    raise exception 'stage15_2: service_role missing DML on junctions';
  end if;

  -- Deny-by-absence: no policy may expose the junctions.
  if exists (
    select 1
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    where c.relnamespace = 'public'::regnamespace
      and c.relname in ('news_audience_groups', 'news_audience_users')
  ) then
    raise exception 'stage15_2: RLS policy exposes an audience junction';
  end if;

  -- private.* helpers stay server-side only.
  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join (values ('anon'), ('authenticated')) as r(rolname)
    where n.nspname = 'private'
      and p.proname in (
        'news_audience_matches', 'news_post_deliverable_to_user',
        'news_audience_mode', 'news_audience_uses_junctions',
        'news_assert_audience_consistent', 'news_audience_guard',
        'news_preview_audience_count', 'news_post_to_json',
        'news_snapshot_version'
      )
      and has_function_privilege(r.rolname, p.oid, 'EXECUTE')
  ) then
    raise exception 'stage15_2: private audience helper is client-callable';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname in (
        'news_audience_matches', 'news_post_deliverable_to_user',
        'news_audience_mode', 'news_audience_uses_junctions',
        'news_assert_audience_consistent', 'news_audience_guard',
        'news_preview_audience_count', 'news_post_to_json'
      )
      and (
        p.prosecdef is not true
        or p.proconfig is null
        or not exists (
          -- search_path must be pinned empty, not merely present.
          select 1
          from unnest(p.proconfig) as cfg
          where cfg in ('search_path=', 'search_path=""')
        )
      )
  ) then
    raise exception 'stage15_2: private helper misses DEFINER/empty search_path';
  end if;

  -- Object inventory.
  if exists (
    select 1
    from (
      values
        ('public', 'admin_set_news_audience'),
        ('public', 'admin_preview_news_audience'),
        ('private', 'news_audience_matches'),
        ('private', 'news_post_deliverable_to_user'),
        ('private', 'news_audience_mode'),
        ('private', 'news_audience_uses_junctions'),
        ('private', 'news_assert_audience_consistent'),
        ('private', 'news_audience_guard'),
        ('private', 'news_preview_audience_count')
    ) as r(nsp, proname)
    where not exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = r.nsp and p.proname = r.proname
    )
  ) then
    raise exception 'stage15_2: expected audience object is missing';
  end if;

  -- Exactly one setter, so no call site can bind the wrong overload.
  if (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_set_news_audience'
  ) <> 1 then
    raise exception 'stage15_2: admin_set_news_audience is overloaded';
  end if;

  -- Junction FKs: two per table, every one cascading.
  if exists (
    select 1
    from (values ('news_audience_groups'), ('news_audience_users')) as t(table_name)
    where (
      select count(*)
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      where c.relnamespace = 'public'::regnamespace
        and c.relname = t.table_name
        and con.contype = 'f'
    ) <> 2
  ) or exists (
    select 1
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relnamespace = 'public'::regnamespace
      and c.relname in ('news_audience_groups', 'news_audience_users')
      and con.contype = 'f'
      and pg_get_constraintdef(con.oid) not ilike '%on delete cascade%'
  ) then
    raise exception 'stage15_2: junction FK/cascade contract broken';
  end if;

  -- Composite primary keys prevent duplicate audience rows.
  if exists (
    select 1
    from (values ('news_audience_groups'), ('news_audience_users')) as t(table_name)
    where not exists (
      select 1
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      where c.relnamespace = 'public'::regnamespace
        and c.relname = t.table_name
        and con.contype = 'p'
        and cardinality(con.conkey) = 2
    )
  ) then
    raise exception 'stage15_2: junction composite primary key missing';
  end if;

  -- The guard must exist on all three tables and stay DEFERRABLE INITIALLY
  -- DEFERRED: a non-deferred guard would break the transactional setter.
  if exists (
    select 1
    from (
      values ('news_posts'), ('news_audience_groups'), ('news_audience_users')
    ) as t(table_name)
    where not exists (
      select 1
      from pg_trigger tg
      join pg_class c on c.oid = tg.tgrelid
      join pg_proc p on p.oid = tg.tgfoid
      where c.relnamespace = 'public'::regnamespace
        and c.relname = t.table_name
        and p.proname = 'news_audience_guard'
        and not tg.tgisinternal
        and tg.tgdeferrable
        and tg.tginitdeferred
    )
  ) then
    raise exception 'stage15_2: audience guard trigger missing or not deferrable';
  end if;

  -- The live enum stays ('all','group'); the richer mode is derived only.
  if (
    select string_agg(e.enumlabel, ',' order by e.enumsortorder)
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    where t.typnamespace = 'public'::regnamespace
      and t.typname = 'news_audience_type'
  ) <> 'all,group' then
    raise exception 'stage15_2: news_audience_type enum changed';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'news_posts'
      and column_name in ('audience_mode', 'audience_user_id')
  ) then
    raise exception 'stage15_2: audience mode must stay derived, not stored';
  end if;

  -- Row-level check still forbids ('all', <group>).
  if not exists (
    select 1
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relnamespace = 'public'::regnamespace
      and c.relname = 'news_posts'
      and con.conname = 'news_posts_audience_chk'
      and pg_get_constraintdef(con.oid) ilike '%all%audience_group_id is null%'
  ) then
    raise exception 'stage15_2: news_posts_audience_chk missing or weakened';
  end if;

  -- Live data must already satisfy the junction-aware invariant.
  if exists (
    select 1
    from public.news_posts n
    where n.audience_type = 'all'
      and (
        exists (select 1 from public.news_audience_groups g where g.news_post_id = n.id)
        or exists (select 1 from public.news_audience_users au where au.news_post_id = n.id)
      )
  ) then
    raise exception 'stage15_2: audience_type=all with non-empty junctions in data';
  end if;

  if exists (
    select 1
    from public.news_posts n
    where n.audience_type = 'group'
      and n.audience_group_id is null
      and not exists (
        select 1 from public.news_audience_groups g where g.news_post_id = n.id
      )
      and not exists (
        select 1 from public.news_audience_users au where au.news_post_id = n.id
      )
  ) then
    raise exception 'stage15_2: group audience without any target in data';
  end if;

  -- Preview must never expose student identities.
  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'news_preview_audience_count'
      and (
        p.prosrc ilike '%u.login%'
        or p.prosrc ilike '%u.name%'
        or p.prosrc ilike '%u.surname%'
        or p.prosrc ilike '%avatar%'
      )
  ) then
    raise exception 'stage15_2: preview reads student PII columns';
  end if;

  -- Admin payloads expose junctions + derived mode (SPEC 15.2 item 6).
  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private'
      and p.proname = 'news_post_to_json'
      and not (
        p.prosrc ilike '%audience_group_ids%'
        and p.prosrc ilike '%audience_user_ids%'
        and p.prosrc ilike '%news_audience_mode%'
      )
  ) then
    raise exception 'stage15_2: admin JSON misses audience junctions or mode';
  end if;

  -- The inline legacy predicate must be gone from the student RPCs.
  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_my_published_news', 'mark_news_seen')
      and p.prosrc ilike '%audience_group_id = any%'
  ) then
    raise exception 'stage15_2: student RPC still inlines the legacy predicate';
  end if;

  raise notice 'stage15_2 structural + data invariants PASSED';
end;
$$;

-- Informational: existing news content is preserved (no destructive rewrite).
select
  (select count(*) from public.news_posts)                             as posts,
  (select count(*) from public.news_versions)                          as versions,
  (select count(*) from public.news_posts where image_path is not null) as posts_with_image,
  (select count(*) from public.news_audience_groups)                   as audience_group_rows,
  (select count(*) from public.news_audience_users)                    as audience_user_rows;
