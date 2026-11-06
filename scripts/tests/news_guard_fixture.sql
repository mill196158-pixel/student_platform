-- Isolated test fixture ONLY; run in a disposable local PostgreSQL database.
create table public.codex_news_guard_fixture(marker text not null);
insert into public.codex_news_guard_fixture values ('DISPOSABLE_LOCAL_ONLY');
do $$ begin
 if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
 if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end $$;
create schema auth;
create schema private;
create schema storage;
create function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('test.uid', true),'')::uuid
$$;
create function private.require_admin_permission(p text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v uuid := auth.uid();
begin
 if v is null then raise exception 'not_authenticated' using errcode='28000'; end if;
 if (p='content.write' and coalesce(current_setting('test.write',true),'0')<>'1')
 or (p='content.publish' and coalesce(current_setting('test.publish',true),'0')<>'1')
 then raise exception 'forbidden' using errcode='42501'; end if;
 return v;
end $$;
create table public.news_posts (
 id uuid primary key, status text not null, version_number integer not null,
 image_path text, updated_by uuid, updated_at timestamptz default now()
);
create table public.news_versions (
 news_post_id uuid not null, version_number integer not null,
 snapshot jsonb not null, primary key(news_post_id,version_number)
);
create table public.test_audit(action text, entity_type text, entity_id text, meta jsonb);
create table storage.objects(bucket_id text not null, name text not null, metadata jsonb not null,
 primary key(bucket_id,name));
create function private.news_snapshot_version(p_id uuid) returns void language sql as $$
 insert into public.news_versions(news_post_id,version_number,snapshot)
 select id,version_number,jsonb_build_object('image_path',image_path) from public.news_posts where id=p_id
 on conflict(news_post_id,version_number) do update set snapshot=excluded.snapshot
$$;
create function private.news_media_path_still_referenced(p_path text) returns boolean language sql as $$
 select exists(select 1 from public.news_posts where image_path=p_path)
    or exists(select 1 from public.news_versions where snapshot->>'image_path'=p_path)
$$;
create function private.admin_write_audit(p_action text,p_type text,p_id text,p_meta jsonb)
returns void language sql as $$
 insert into public.test_audit(action,entity_type,entity_id,meta) values(p_action,p_type,p_id,p_meta)
$$;
