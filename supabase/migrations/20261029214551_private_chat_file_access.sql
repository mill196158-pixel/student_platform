-- Canonical object provenance. No client can mint or change a trusted key.
create table private.chat_file_objects (
  file_key text primary key,
  chat_id uuid not null,
  uploaded_by uuid not null,
  file_id uuid unique references public.chat_files(id) on delete set null,
  file_name text not null,
  file_type text not null,
  file_size bigint not null check(file_size > 0),
  file_url text not null,
  confirmed boolean not null default false,
  delete_requested_at timestamptz,
  deleted_at timestamptz,
  expires_at timestamptz not null default now()+interval '1 hour',
  created_at timestamptz not null default now()
);
alter table private.chat_file_objects enable row level security;
alter table private.chat_file_objects force row level security;
revoke all on private.chat_file_objects from public,anon,authenticated;

-- Audited legacy rows: all 50 keys have the correct chat prefix and are unique.
do $$ begin
  if exists(select 1 from public.chat_files where file_key not like 'chats/'||chat_id::text||'/%'
      or file_key is null or file_size is null or file_size <= 0)
    or exists(select file_key from public.chat_files group by file_key having count(*)>1)
  then raise exception 'legacy_file_inventory_changed'; end if;
end $$;
insert into private.chat_file_objects(file_key,chat_id,uploaded_by,file_id,file_name,file_type,file_size,file_url,confirmed)
select file_key,chat_id,uploaded_by,id,file_name,file_type,file_size,file_url,true from public.chat_files;

create function public.begin_chat_file_upload(p_key text,p_chat uuid,p_actor uuid,p_name text,p_type text,p_size bigint,p_url text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if auth.jwt()->>'role' is distinct from 'service_role' then raise exception 'forbidden' using errcode='42501'; end if;
  if p_key not like 'chats/'||p_chat::text||'/%/'||p_actor::text||'/%'
    or p_size not between 1 and 104857600 or length(p_name) not between 1 and 255
    or not exists(select 1 from auth.users where id=p_actor)
    or not (exists(select 1 from public.chat_members where chat_id=p_chat and user_id=p_actor)
      or exists(select 1 from public.chats c join public.team_members tm on tm.team_id=c.team_id where c.id=p_chat and tm.user_id=p_actor))
  then raise exception 'invalid_upload' using errcode='42501'; end if;
  insert into private.chat_file_objects(file_key,chat_id,uploaded_by,file_name,file_type,file_size,file_url)
  values(p_key,p_chat,p_actor,p_name,p_type,p_size,p_url);
end $$;
revoke all on function public.begin_chat_file_upload(text,uuid,uuid,text,text,bigint,text) from public,anon,authenticated;
grant execute on function public.begin_chat_file_upload(text,uuid,uuid,text,text,bigint,text) to service_role;

create function public.inspect_chat_file_upload(p_key text,p_actor uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype;
begin
  if auth.jwt()->>'role' is distinct from 'service_role' then raise exception 'forbidden' using errcode='42501'; end if;
  select * into o from private.chat_file_objects where file_key=p_key and uploaded_by=p_actor and expires_at>now();
  if not found then raise exception 'upload_missing' using errcode='42501'; end if;
  return jsonb_build_object('key',o.file_key,'size',o.file_size,'type',o.file_type);
end $$;
revoke all on function public.inspect_chat_file_upload(text,uuid) from public,anon,authenticated;
grant execute on function public.inspect_chat_file_upload(text,uuid) to service_role;

create function public.confirm_chat_file_upload(p_key text,p_actor uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if auth.jwt()->>'role' is distinct from 'service_role' then raise exception 'forbidden' using errcode='42501'; end if;
  update private.chat_file_objects set confirmed=true where file_key=p_key and uploaded_by=p_actor and expires_at>now();
  if not found then raise exception 'upload_missing' using errcode='42501'; end if;
end $$;
revoke all on function public.confirm_chat_file_upload(text,uuid) from public,anon,authenticated;
grant execute on function public.confirm_chat_file_upload(text,uuid) to service_role;

create or replace function public.save_chat_file(p_chat_id uuid,p_file_name text,p_file_key text,p_file_url text,p_file_type text,p_file_size bigint,p_uploaded_by uuid default null,p_message_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; result uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  select * into o from private.chat_file_objects where file_key=p_file_key for update;
  if not found or o.uploaded_by<>auth.uid() or o.chat_id<>p_chat_id or not o.confirmed or o.delete_requested_at is not null
    or (o.file_id is null and o.expires_at<=now()) then raise exception 'untrusted_upload' using errcode='42501'; end if;
  if not (exists(select 1 from public.chat_members where chat_id=p_chat_id and user_id=auth.uid())
    or exists(select 1 from public.chats c join public.team_members tm on tm.team_id=c.team_id where c.id=p_chat_id and tm.user_id=auth.uid()))
  then raise exception 'forbidden' using errcode='42501'; end if;
  if p_message_id is not null and not exists(select 1 from public.messages where id=p_message_id and chat_id=p_chat_id and author_id=auth.uid())
  then raise exception 'invalid_message' using errcode='42501'; end if;
  if o.file_id is not null then return o.file_id; end if;
  insert into public.chat_files(chat_id,file_name,file_key,file_url,file_type,file_size,uploaded_by,message_id)
  values(o.chat_id,o.file_name,o.file_key,o.file_url,o.file_type,o.file_size,o.uploaded_by,p_message_id) returning id into result;
  update private.chat_file_objects set file_id=result where file_key=p_file_key;
  return result;
end $$;
-- One overload handles both six- and eight-argument API payloads.
drop function public.save_chat_file(uuid,text,text,text,text,bigint);
revoke all on function public.save_chat_file(uuid,text,text,text,text,bigint,uuid,uuid) from public,anon;
grant execute on function public.save_chat_file(uuid,text,text,text,text,bigint,uuid,uuid) to authenticated;

-- Match get_chat_messages_page read semantics, including retained archives.
create function private.can_read_chat_file_chat(p_chat uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null
    and not exists(select 1 from public.chat_academic_archives a where a.chat_id=p_chat and a.expired_at is not null)
    and exists(select 1 from public.chats c where c.id=p_chat and (
      (c.type='dm' and exists(select 1 from public.chat_members cm where cm.chat_id=c.id and cm.user_id=auth.uid()))
      or (c.type='team_main' and c.team_id is not null and (
        exists(select 1 from public.team_members tm where tm.team_id=c.team_id and tm.user_id=auth.uid())
        or exists(select 1 from public.teams t join public.users u on u.id=auth.uid() where t.id=c.team_id and t.group_name is not null and t.group_name=u.group_name)
      ))));
$$;
revoke all on function private.can_read_chat_file_chat(uuid) from public,anon,authenticated;

create function public.resolve_chat_file_access(p_key text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; f public.chat_files%rowtype; proof record; allowed boolean:=false; has_proof boolean:=false;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  select * into o from private.chat_file_objects where file_key=p_key and file_id is not null and delete_requested_at is null and deleted_at is null;
  if not found or not private.can_read_chat_file_chat(o.chat_id) then raise exception 'file_unavailable' using errcode='42501'; end if;
  select * into f from public.chat_files where id=o.file_id and chat_id=o.chat_id and uploaded_by=o.uploaded_by and file_key=o.file_key and not coalesce(is_deleted,false);
  if not found then raise exception 'file_unavailable' using errcode='42501'; end if;
  for proof in select cc.user_id,gc.team_id from public.group_collection_contributions cc join public.group_collections gc on gc.id=cc.collection_id where cc.proof_file_id=f.id loop
    has_proof:=true;
    if private.is_active_team_member(proof.team_id) and (auth.uid()=proof.user_id or private.can_manage_team_collections(proof.team_id)) then allowed:=true; end if;
  end loop;
  if not has_proof and not coalesce(f.is_sensitive,false) then
    allowed:=true;
  end if;
  if not allowed then raise exception 'file_unavailable' using errcode='42501'; end if;
  return jsonb_build_object('id',f.id,'key',o.file_key,'name',o.file_name,'type',o.file_type,'size',o.file_size,'cacheable',not has_proof and not coalesce(f.is_sensitive,false));
end $$;
revoke all on function public.resolve_chat_file_access(text) from public,anon;
grant execute on function public.resolve_chat_file_access(text) to authenticated;

-- Only server registration can establish provenance. Filename/deletion remain
-- owner-scoped by existing RLS; relationship mutations move through RPCs.
revoke insert,update on public.chat_files from public,anon,authenticated;
revoke insert(id,chat_id,message_id,file_name,file_key,file_url,file_type,file_size,uploaded_by,uploaded_at,is_deleted,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number,is_sensitive), update(id,chat_id,message_id,file_key,file_url,file_type,file_size,uploaded_by,uploaded_at,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number,is_sensitive) on public.chat_files from public,anon,authenticated;
grant update(file_name,is_deleted) on public.chat_files to authenticated;

create function public.save_collection_proof_upload(p_key text) returns uuid
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; result uuid;
begin
  select * into o from private.chat_file_objects where file_key=p_key and uploaded_by=auth.uid() for update;
  if not found then raise exception 'forbidden' using errcode='42501'; end if;
  result:=public.save_chat_file(o.chat_id,o.file_name,o.file_key,o.file_url,o.file_type,o.file_size,null::uuid,null::uuid);
  if exists(select 1 from public.chat_files where id=result and message_id is not null)
  then raise exception 'already_attached' using errcode='42501'; end if;
  update public.chat_files set is_sensitive=true where id=result;
  return result;
end $$;
revoke all on function public.save_collection_proof_upload(text) from public,anon;
grant execute on function public.save_collection_proof_upload(text) to authenticated;

create function public.detach_my_message_files(p_message_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.messages where id=p_message_id and author_id=auth.uid())
  then raise exception 'forbidden' using errcode='42501'; end if;
  update public.chat_files set message_id=null where message_id=p_message_id and uploaded_by=auth.uid();
end $$;
revoke all on function public.detach_my_message_files(uuid) from public,anon;
grant execute on function public.detach_my_message_files(uuid) to authenticated;

create function private.chat_file_has_references(p_file uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.chat_files where id=p_file and message_id is not null)
    or exists(select 1 from public.messages where file_id=p_file)
    or exists(select 1 from public.group_topic_selections where source_file_id=p_file)
    or exists(select 1 from public.group_collection_contributions where proof_file_id=p_file);
$$;
revoke all on function private.chat_file_has_references(uuid) from public,anon,authenticated;

create function private.guard_chat_file_reference() returns trigger
language plpgsql security definer set search_path='' as $$
declare target uuid; f public.chat_files%rowtype; o private.chat_file_objects%rowtype;
begin
  target:=(to_jsonb(new)->>tg_argv[0])::uuid;
  if target is null then return new; end if;
  if tg_op='UPDATE' and (to_jsonb(old)->>tg_argv[0])::uuid is not distinct from target then return new; end if;
  select * into f from public.chat_files where id=target for update;
  if not found or coalesce(f.is_deleted,false) then raise exception 'file_unavailable' using errcode='42501'; end if;
  select * into o from private.chat_file_objects where file_id=target;
  if not found or not o.confirmed or o.delete_requested_at is not null or o.deleted_at is not null
    or o.file_key<>f.file_key or o.chat_id<>f.chat_id or o.uploaded_by<>f.uploaded_by
    or (tg_argv[1]='normal' and (coalesce(f.is_sensitive,false) or exists(select 1 from public.group_collection_contributions where proof_file_id=target)))
  then raise exception 'file_unavailable' using errcode='42501'; end if;
  if tg_table_name='messages' and (to_jsonb(new)->>'chat_id')::uuid is distinct from f.chat_id then
    raise exception 'file_chat_mismatch' using errcode='42501';
  elsif tg_table_name='group_topic_selections' and private.team_main_chat_id((to_jsonb(new)->>'team_id')::uuid) is distinct from f.chat_id then
    raise exception 'file_chat_mismatch' using errcode='42501';
  elsif tg_table_name='group_collection_contributions' then
    if (to_jsonb(new)->>'user_id')::uuid is distinct from f.uploaded_by or
      not exists(select 1 from public.group_collections gc where gc.id=(to_jsonb(new)->>'collection_id')::uuid and private.team_main_chat_id(gc.team_id)=f.chat_id)
    then raise exception 'proof_owner_mismatch' using errcode='42501'; end if;
  end if;
  return new;
end $$;
revoke all on function private.guard_chat_file_reference() from public,anon,authenticated;
create trigger guard_topic_source_file before insert or update of source_file_id on public.group_topic_selections
for each row execute function private.guard_chat_file_reference('source_file_id','normal');
create trigger guard_message_file before insert or update of file_id on public.messages
for each row execute function private.guard_chat_file_reference('file_id','normal');
create trigger guard_collection_proof before insert or update of proof_file_id on public.group_collection_contributions
for each row execute function private.guard_chat_file_reference('proof_file_id','proof');

-- Cover legacy SECURITY DEFINER senders as well as the current send RPC.
create function private.guard_chat_file_message_binding() returns trigger
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype;
begin
  if new.message_id is null then return new; end if;
  if tg_op='UPDATE' and old.message_id is not distinct from new.message_id then return new; end if;
  select * into o from private.chat_file_objects where file_key=new.file_key;
  if not found or not o.confirmed or o.delete_requested_at is not null or o.deleted_at is not null
    or o.chat_id<>new.chat_id or o.uploaded_by<>new.uploaded_by
    or (o.file_id is not null and o.file_id<>new.id)
    or coalesce(new.is_deleted,false) or coalesce(new.is_sensitive,false)
    or exists(select 1 from public.group_collection_contributions where proof_file_id=new.id)
    or not exists(select 1 from public.messages m where m.id=new.message_id and m.chat_id=new.chat_id
      and m.author_id=new.uploaded_by)
    or (auth.uid() is not null and auth.uid()<>new.uploaded_by)
  then raise exception 'invalid_file_binding' using errcode='42501'; end if;
  if tg_op='UPDATE' and old.message_id is not null then
    raise exception 'file_already_attached' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function private.guard_chat_file_message_binding() from public,anon,authenticated;
create trigger guard_chat_file_message_binding before insert or update of message_id on public.chat_files
for each row execute function private.guard_chat_file_message_binding();

create function public.discard_unattached_chat_upload(p_key text) returns boolean
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; f public.chat_files%rowtype;
begin
  select * into o from private.chat_file_objects where file_key=p_key and uploaded_by=auth.uid() for update;
  if not found then raise exception 'forbidden' using errcode='42501'; end if;
  if o.file_id is not null then
    select * into f from public.chat_files where id=o.file_id for update;
    if private.chat_file_has_references(o.file_id)
      then return false; end if;
    update public.chat_files set is_deleted=true where id=o.file_id;
  end if;
  update private.chat_file_objects set delete_requested_at=coalesce(delete_requested_at,now()) where file_key=p_key;
  return true;
end $$;
revoke all on function public.discard_unattached_chat_upload(text) from public,anon;
grant execute on function public.discard_unattached_chat_upload(text) to authenticated;

create function public.claim_chat_upload_cleanup(p_limit integer default 20) returns table(file_key text)
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; f public.chat_files%rowtype;
begin
  if auth.jwt()->>'role' is distinct from 'service_role' then raise exception 'forbidden' using errcode='42501'; end if;
  for o in select x.* from private.chat_file_objects x where x.expires_at<now() and x.deleted_at is null
    and (x.delete_requested_at is not null or x.file_id is null)
    order by x.created_at limit least(greatest(p_limit,1),25) for update skip locked loop
    if o.file_id is not null then
      select * into f from public.chat_files where id=o.file_id for update;
      if private.chat_file_has_references(o.file_id)
      then continue; end if;
      update public.chat_files set is_deleted=true where id=o.file_id;
    end if;
    update private.chat_file_objects x set delete_requested_at=coalesce(x.delete_requested_at,now()) where x.file_key=o.file_key;
    file_key:=o.file_key; return next;
  end loop;
end $$;
revoke all on function public.claim_chat_upload_cleanup(integer) from public,anon,authenticated;
grant execute on function public.claim_chat_upload_cleanup(integer) to service_role;

create function public.complete_chat_upload_cleanup(p_key text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if auth.jwt()->>'role' is distinct from 'service_role' then raise exception 'forbidden' using errcode='42501'; end if;
  update private.chat_file_objects set deleted_at=now() where file_key=p_key and delete_requested_at is not null and expires_at<now();
end $$;
revoke all on function public.complete_chat_upload_cleanup(text) from public,anon,authenticated;
grant execute on function public.complete_chat_upload_cleanup(text) to service_role;

CREATE OR REPLACE FUNCTION public.send_message_in_chat_with_files(p_chat_id uuid, p_text text, p_reply_to uuid DEFAULT NULL::uuid, p_file_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  me uuid := auth.uid();
  v_mid uuid;
  v_has_files boolean := (coalesce(array_length(p_file_ids,1),0) > 0);
begin
  if me is null then raise exception 'auth required'; end if;

  if not exists (
    select 1 from public.chat_members cm
    where cm.chat_id = p_chat_id and cm.user_id = me
  ) and not exists (
    select 1
    from public.chats c
    join public.team_members tm on tm.team_id = c.team_id
    where c.id = p_chat_id and tm.user_id = me
  ) then
    raise exception 'forbidden';
  end if;


  if cardinality(coalesce(p_file_ids,'{}'))>10
     or cardinality(coalesce(p_file_ids,'{}'))<>(select count(distinct x) from unnest(p_file_ids) x)
  then raise exception 'invalid_files' using errcode='22023'; end if;
  if p_reply_to is not null and not exists(select 1 from public.messages where id=p_reply_to and chat_id=p_chat_id)
  then raise exception 'invalid_reply' using errcode='42501'; end if;
  perform 1 from public.chat_files where id=any(p_file_ids) order by id for update;
  if (select count(*) from public.chat_files f join private.chat_file_objects o on o.file_id=f.id
      where f.id=any(p_file_ids) and f.chat_id=p_chat_id and f.uploaded_by=me
        and f.message_id is null and not coalesce(f.is_deleted,false) and not coalesce(f.is_sensitive,false)
        and o.confirmed and o.delete_requested_at is null and o.deleted_at is null
        and o.file_key=f.file_key and o.chat_id=f.chat_id and o.uploaded_by=f.uploaded_by
        and not exists(select 1 from public.group_collection_contributions where proof_file_id=f.id)
     )<>cardinality(coalesce(p_file_ids,'{}'))
  then raise exception 'invalid_files' using errcode='42501'; end if;

  insert into public.messages(id, chat_id, author_id, content, body, msg_type, reply_to_id, attachments, reactions)
  values (
    gen_random_uuid(),
    p_chat_id,
    me,
    coalesce(p_text, ''),
    coalesce(p_text, ''),
    case when v_has_files then 'file' else 'text' end,
    p_reply_to,
    '[]'::jsonb,
    '{}'::jsonb
  )
  returning id into v_mid;

  if v_has_files then
    update public.chat_files f
       set message_id = v_mid
     where f.id = any(p_file_ids)
       and f.chat_id = p_chat_id
       and f.uploaded_by = me
       and f.message_id is null;
  end if;

  return v_mid;
end $function$;

revoke all on function public.send_message_in_chat_with_files(uuid,text,uuid,uuid[]) from public,anon;
grant execute on function public.send_message_in_chat_with_files(uuid,text,uuid,uuid[]) to authenticated;
