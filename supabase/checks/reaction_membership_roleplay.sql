BEGIN;
-- Run inside BEGIN/ROLLBACK with test.actor_a, test.actor_b, test.outsider,
-- test.chat_id set to isolated fixture UUIDs. Never use real users for fixtures.

do $test$
declare
 a uuid := current_setting('test.actor_a');
 b uuid := current_setting('test.actor_b');
 outsider uuid := current_setting('test.outsider');
 cid uuid := current_setting('test.chat_id');
 mid uuid; old_reactions jsonb; old_count int; got jsonb; tid uuid; teamchat uuid; teammsg uuid;
 yr uuid; term uuid;
begin
 select id into strict mid from public.messages where chat_id=cid and author_id=a order by created_at desc limit 1;
 select reactions into old_reactions from public.messages where id=mid;
 select count(*) into old_count from public.message_reactions where message_id=mid;
 perform set_config('request.jwt.claims',json_build_object('sub',outsider,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin
  perform public.toggle_message_reaction(mid,'test-denied');
  raise exception 'test: outsider allowed';
 exception when sqlstate 'P0001' then
  if sqlerrm <> 'forbidden' then raise; end if;
 end;
 if (select count(*) from public.message_reactions where message_id=mid)<>old_count
 or (select reactions from public.messages where id=mid) is distinct from old_reactions then raise exception 'test: outsider changed state'; end if;
 perform set_config('request.jwt.claims',json_build_object('sub',a,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',a::text,true);
 got := public.toggle_message_reaction(mid,'test-add');
 if not got ? 'test-add' then raise exception 'test: add failed'; end if;
 got := public.toggle_message_reaction(mid,'test-change');
 if got ? 'test-add' or not got ? 'test-change' then raise exception 'test: change failed'; end if;
 got := public.toggle_message_reaction(mid,'test-change');
 if got ? 'test-change' then raise exception 'test: remove failed'; end if;
 insert into public.teams(name,group_name,owner_id) values ('E2E reaction guard rollback','E2E reaction guard rollback',a) returning id into tid;
 select id into teamchat from public.chats where team_id=tid and type='team_main';
 if teamchat is null then insert into public.chats(team_id,type) values(tid,'team_main') returning id into teamchat; end if;
 insert into public.team_members(team_id,user_id,role) values(tid,a,'member') on conflict do nothing;
 insert into public.messages(chat_id,author_id,content,body,msg_type) values(teamchat,a,'E2E rollback','E2E rollback','text') returning id into teammsg;
 got:=public.toggle_message_reaction(teammsg,'member');
 if not got ? 'member' then raise exception 'test: team member failed'; end if;
 perform set_config('request.jwt.claims',json_build_object('sub',b,'role','service_role')::text,true);
 perform set_config('request.jwt.claim.sub',b::text,true);
 update public.users set group_name='E2E reaction guard rollback' where id=b;
 perform set_config('request.jwt.claims',json_build_object('sub',b,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',b::text,true);
 got:=public.toggle_message_reaction(teammsg,'group-reader');
 if not got ? 'group-reader' then raise exception 'test: group reader failed'; end if;
 insert into public.academic_years(name,start_year,starts_on,ends_on,is_current) values ('E2E rollback 2098',2098,'2098-01-01','2098-12-31',false) returning id into yr;
 insert into public.academic_terms(academic_year_id,term_in_year,term_sequence,name,starts_on,ends_on,is_current) values(yr,1,99999,'E2E rollback term','2098-01-01','2098-06-30',false) returning id into term;
 insert into public.chat_academic_archives(chat_id,academic_term_id,archived_at,available_until) values(teamchat,term,now(),now()+interval '1 year');
 begin
  perform public.toggle_message_reaction(teammsg,'archive');
  raise exception 'test: archive allowed';
 exception when sqlstate 'P0001' then
  if sqlerrm <> 'academic_chat_archived' then raise; end if;
 end;
 if has_function_privilege('anon','public.toggle_message_reaction(uuid,text)','execute') then raise exception 'test: anon permission'; end if;
 if not has_function_privilege('authenticated','public.toggle_message_reaction(uuid,text)','execute') then raise exception 'test: missing member grant'; end if;
end $test$;
select 'PASS: outsider unchanged, member add/change/remove, team member, group reader, archive denied, grants' as result;


ROLLBACK;
