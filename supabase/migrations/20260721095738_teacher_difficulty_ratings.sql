create schema if not exists private;
revoke all on schema private from public;

create table if not exists public.teacher_difficulty_targets (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  normalized_name text not null unique,
  created_at timestamptz not null default now(),
  constraint teacher_difficulty_targets_name_not_blank
    check (btrim(display_name) <> '' and btrim(normalized_name) <> '')
);

create table if not exists public.teacher_difficulty_votes (
  teacher_id uuid not null
    references public.teacher_difficulty_targets(id) on delete cascade,
  user_id uuid not null
    references auth.users(id) on delete cascade default auth.uid(),
  score smallint not null check (score between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (teacher_id, user_id)
);

create index if not exists teacher_difficulty_votes_user_id_idx
  on public.teacher_difficulty_votes (user_id);

create table if not exists public.teacher_difficulty_summaries (
  teacher_id uuid primary key
    references public.teacher_difficulty_targets(id) on delete cascade,
  vote_count integer not null default 0 check (vote_count >= 0),
  score_total integer not null default 0 check (score_total >= 0),
  updated_at timestamptz not null default now()
);

create or replace function private.recompute_teacher_difficulty(
  p_teacher_id uuid
)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  insert into public.teacher_difficulty_summaries (
    teacher_id,
    vote_count,
    score_total,
    updated_at
  )
  select
    p_teacher_id,
    count(*)::integer,
    coalesce(sum(v.score), 0)::integer,
    now()
  from public.teacher_difficulty_votes v
  where v.teacher_id = p_teacher_id
  on conflict (teacher_id) do update
  set vote_count = excluded.vote_count,
      score_total = excluded.score_total,
      updated_at = excluded.updated_at;
$$;

revoke all on function private.recompute_teacher_difficulty(uuid) from public;

create or replace function private.sync_teacher_difficulty_summary()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if tg_op = 'DELETE' then
    perform private.recompute_teacher_difficulty(old.teacher_id);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.teacher_id is distinct from new.teacher_id then
    perform private.recompute_teacher_difficulty(old.teacher_id);
  end if;

  perform private.recompute_teacher_difficulty(new.teacher_id);
  return new;
end;
$$;

revoke all on function private.sync_teacher_difficulty_summary() from public;

create or replace function private.set_teacher_difficulty_vote_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_teacher_difficulty_vote_updated_at()
  from public;

drop trigger if exists teacher_difficulty_votes_set_updated_at
  on public.teacher_difficulty_votes;
create trigger teacher_difficulty_votes_set_updated_at
before update on public.teacher_difficulty_votes
for each row
execute function private.set_teacher_difficulty_vote_updated_at();

drop trigger if exists teacher_difficulty_votes_sync_summary
  on public.teacher_difficulty_votes;
create trigger teacher_difficulty_votes_sync_summary
after insert or update or delete on public.teacher_difficulty_votes
for each row
execute function private.sync_teacher_difficulty_summary();

insert into public.teacher_difficulty_targets (
  display_name,
  normalized_name
)
select
  source.full_name,
  lower(regexp_replace(source.full_name, '\s+', ' ', 'g'))
from (
  select distinct btrim(teacher) as full_name
  from public.lessons
  where nullif(btrim(teacher), '') is not null

  union

  select distinct btrim(teacher) as full_name
  from public.teams
  where nullif(btrim(teacher), '') is not null
) source
where source.full_name !~* '^тест'
on conflict (normalized_name) do update
set display_name = excluded.display_name;

insert into public.teacher_difficulty_summaries (
  teacher_id,
  vote_count,
  score_total
)
select id, 0, 0
from public.teacher_difficulty_targets
on conflict (teacher_id) do nothing;

alter table public.teacher_difficulty_targets enable row level security;
alter table public.teacher_difficulty_votes enable row level security;
alter table public.teacher_difficulty_summaries enable row level security;

drop policy if exists teacher_difficulty_targets_authenticated_read
  on public.teacher_difficulty_targets;
create policy teacher_difficulty_targets_authenticated_read
on public.teacher_difficulty_targets
for select
to authenticated
using (true);

drop policy if exists teacher_difficulty_votes_read_own
  on public.teacher_difficulty_votes;
create policy teacher_difficulty_votes_read_own
on public.teacher_difficulty_votes
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists teacher_difficulty_votes_insert_own
  on public.teacher_difficulty_votes;
create policy teacher_difficulty_votes_insert_own
on public.teacher_difficulty_votes
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists teacher_difficulty_votes_update_own
  on public.teacher_difficulty_votes;
create policy teacher_difficulty_votes_update_own
on public.teacher_difficulty_votes
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists teacher_difficulty_votes_delete_own
  on public.teacher_difficulty_votes;
create policy teacher_difficulty_votes_delete_own
on public.teacher_difficulty_votes
for delete
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists teacher_difficulty_summaries_authenticated_read
  on public.teacher_difficulty_summaries;
create policy teacher_difficulty_summaries_authenticated_read
on public.teacher_difficulty_summaries
for select
to authenticated
using (true);

revoke all on table public.teacher_difficulty_targets from anon;
revoke all on table public.teacher_difficulty_votes from anon;
revoke all on table public.teacher_difficulty_summaries from anon;
revoke all on table public.teacher_difficulty_targets from authenticated;
revoke all on table public.teacher_difficulty_votes from authenticated;
revoke all on table public.teacher_difficulty_summaries from authenticated;

grant select on table public.teacher_difficulty_targets to authenticated;
grant select, insert, update, delete
  on table public.teacher_difficulty_votes to authenticated;
grant select on table public.teacher_difficulty_summaries to authenticated;
