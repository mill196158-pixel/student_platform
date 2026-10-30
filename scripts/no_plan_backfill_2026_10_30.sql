begin;
create temporary table np_before as select id,subject_id,subject_offering_id from public.lessons where group_id in ('09f0c211-9570-43cf-8417-366a83c536d6','a652632a-1d95-495f-abdc-23eda79ee7a1') and date between '2025-09-01' and '2025-11-20';
create temporary table np_counts as select (select count(*) from public.teams) teams,(select count(*) from public.chats) chats,(select count(*) from public.team_members) members;
create temporary table np_results(result jsonb);
do $$
declare g uuid; preview jsonb; applied jsonb;
begin
foreach g in array array['09f0c211-9570-43cf-8417-366a83c536d6'::uuid,'a652632a-1d95-495f-abdc-23eda79ee7a1'::uuid] loop
assert (select count(*)=88 from public.lessons where group_id=g and date between '2025-09-01' and '2025-11-20'),'scope count changed';
assert not exists(select 1 from public.academic_terms where is_current and daterange(starts_on,ends_on,'[]') && daterange(date '2025-09-01',date '2025-11-20','[]')),'current term';
preview:=private.sync_schedule_subjects(g,'2025-09-01','2025-11-20',true);
assert (preview->>'pending')::int=0 and (preview->>'linked')::int=88,'preview changed';
applied:=private.sync_schedule_subjects(g,'2025-09-01','2025-11-20',false);
assert (applied->>'pending')::int=0 and (applied->>'linked')::int=88 and (applied->>'created_teams')::int=0,'apply mismatch';
insert into np_results values(applied);
end loop;
assert not exists(select 1 from np_before b join public.lessons l using(id) where (b.subject_id is not null and b.subject_id is distinct from l.subject_id) or (b.subject_offering_id is not null and b.subject_offering_id is distinct from l.subject_offering_id)),'existing links changed';
assert (select teams=(select count(*) from public.teams) and chats=(select count(*) from public.chats) and members=(select count(*) from public.team_members) from np_counts),'chat counts changed';
end $$;
select result from np_results;
commit;
