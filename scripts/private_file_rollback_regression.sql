-- Synthetic-only transaction; always rolled back by runner.
do $$
declare a uuid:='475888d2-fbef-43c0-8cc6-30d5857b7d85'; b uuid:='49323ae4-1409-4993-9969-12b2ae573f8c'; outsider uuid:='50e4beea-5a14-4ab1-8c8a-635b94161850';
 g uuid; t uuid; c uuid; f uuid; k text; coll uuid; again uuid; receipt uuid:=gen_random_uuid(); obj jsonb;
begin
 insert into public.groups(name) values('E2E rollback private files') returning id into g;
 insert into public.teams(name,kind,group_id,owner_id,group_name) values('E2E rollback','group_space',g,a,'E2E-'||g::text) returning id into t;
 select id into c from public.chats where team_id=t and type='team_main';
 insert into public.team_members(team_id,user_id,role) values(t,b,'member') on conflict do nothing;
 insert into public.chat_members(chat_id,user_id,role_in_chat) values(c,b,'member') on conflict do nothing;
 insert into public.student_enrollments(user_id,group_id) values(a,g),(b,g);
 k:='chats/'||c||'/test/'||a||'/fixture.txt';
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','service_role')::text,true);
 perform public.begin_chat_file_upload(k,c,a,'fixture.txt','text/plain',10,'https://studentsplatform.storage.yandexcloud.net/'||k);
 perform public.confirm_chat_file_upload(k,a);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 f:=public.save_chat_file(c,'forged',k,'https://evil.invalid','fake/type',999);
 if not exists(select 1 from public.chat_files where id=f and file_size=10 and file_name='fixture.txt') then raise exception 'canonical metadata failed'; end if;
 if public.save_chat_file(c,'x',k,'x','x',1,a,null)<>f then raise exception 'save idempotency failed'; end if;
 perform public.resolve_chat_file_access(k);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
 perform public.resolve_chat_file_access(k);
 begin
  perform public.send_chat_message(t,'steal',p_file_id=>f);
  raise exception 'TEST FAILED legacy foreign binding accepted';
 exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true);
 begin perform public.resolve_chat_file_access(k); raise exception 'TEST FAILED outsider read'; exception when insufficient_privilege then null; end;
 begin perform public.save_chat_file(c,'x',k,'x','x',1); raise exception 'TEST FAILED forged save'; exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
 coll:=public.create_group_collection_with_files(receipt,'E2E collection',p_file_ids=>array[f]);
 again:=public.create_group_collection_with_files(receipt,'E2E collection',p_file_ids=>array[f]);
 if coll<>again then raise exception 'TEST FAILED duplicate publication'; end if;
 if not exists(select 1 from public.chat_files cf join public.group_collections gc on gc.card_message_id=cf.message_id where cf.id=f and gc.id=coll) then raise exception 'TEST FAILED attachment'; end if;
 if public.discard_unattached_chat_upload(k) then raise exception 'TEST FAILED referenced discard'; end if;
 begin perform public.send_chat_message(t,'rebind',p_file_id=>f); raise exception 'TEST FAILED rebind'; exception when insufficient_privilege then null; end;
 if has_column_privilege('authenticated','public.chat_files','file_key','UPDATE') or has_column_privilege('authenticated','public.chat_files','message_id','UPDATE') or has_table_privilege('anon','private.chat_file_objects','SELECT') then raise exception 'TEST FAILED grants'; end if;
 if not has_column_privilege('authenticated','public.chat_files','file_name','UPDATE') then raise exception 'TEST FAILED rename grant'; end if;
end $$;
select 'PASS canonical save six/eight, owner/member/outsider, legacy foreign/rebind, atomic collection retry, referenced discard, column ACL' as result;
