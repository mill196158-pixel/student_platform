-- Groups are read-only for application clients. All writes go through the
-- existing capability-checked admin/import SECURITY DEFINER functions.
revoke insert,update,delete,truncate,references,trigger on public.groups from public,anon,authenticated;
revoke select on public.groups from public,anon;
do $$ declare c record; begin
 for c in select column_name from information_schema.columns where table_schema='public' and table_name='groups' loop
  execute format('revoke insert (%I), update (%I), references (%I) on public.groups from public, anon, authenticated',c.column_name,c.column_name,c.column_name);
  execute format('revoke select (%I) on public.groups from public, anon',c.column_name);
 end loop;
end $$;
alter table public.groups enable row level security;
grant select on public.groups to authenticated;
create policy groups_authenticated_read on public.groups for select to authenticated using (true);
