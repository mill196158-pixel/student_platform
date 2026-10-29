alter table private.chat_file_objects add column diary_file_id uuid unique references public.subject_diary_files(id) on delete set null;
alter table private.chat_file_objects add constraint one_file_namespace check(file_id is null or diary_file_id is null);
do $$ begin
 if exists(select 1 from public.subject_diary_files f join public.subject_diary_entries e on e.id=f.entry_id where f.uploaded_by<>e.author_id or split_part(f.yandex_key,'/',1)<>'diaries' or split_part(f.yandex_key,'/',3)<>e.author_id::text or f.size_bytes is null or f.size_bytes<=0)
 or exists(select yandex_key from public.subject_diary_files group by yandex_key having count(*)>1)
 then raise exception 'legacy_diary_inventory_changed';end if;
end $$;
insert into private.chat_file_objects(file_key,chat_id,uploaded_by,diary_file_id,file_name,file_type,file_size,file_url,confirmed)
select f.yandex_key,c.id,e.author_id,f.id,regexp_replace(f.yandex_key,'^.*/',''),f.mime,f.size_bytes,f.file_url,true
from public.subject_diary_files f join public.subject_diary_entries e on e.id=f.entry_id
join public.chats c on c.team_id=e.team_id and c.type='team_main';

do $$ begin
 if (select count(*) from private.chat_file_objects where diary_file_id is not null)<>(select count(*) from public.subject_diary_files) then raise exception 'diary_backfill_incomplete';end if;
end $$;

alter function public.resolve_chat_file_access(text) set schema private;
alter function private.resolve_chat_file_access(text) rename to resolve_chat_attachment_access;
revoke all on function private.resolve_chat_attachment_access(text) from public,anon,authenticated;
create function public.resolve_chat_file_access(p_key text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype;
begin
 select * into o from private.chat_file_objects where file_key=p_key;
 if found and o.diary_file_id is not null then
   if auth.uid() is null or o.uploaded_by<>auth.uid() or o.delete_requested_at is not null or o.deleted_at is not null
     or not exists(select 1 from public.subject_diary_files f join public.subject_diary_entries e on e.id=f.entry_id
       where f.id=o.diary_file_id and f.yandex_key=o.file_key and f.uploaded_by=auth.uid() and e.author_id=auth.uid())
   then raise exception 'file_unavailable' using errcode='42501';end if;
   return jsonb_build_object('id',o.diary_file_id,'key',o.file_key,'name',o.file_name,'type',o.file_type,'size',o.file_size,'cacheable',true);
 end if;
 return private.resolve_chat_attachment_access(p_key);
end $$;
revoke all on function public.resolve_chat_file_access(text) from public,anon;
grant execute on function public.resolve_chat_file_access(text) to authenticated;

create or replace function public.add_subject_diary_file(p_entry_id uuid,p_yandex_key text,p_file_url text,p_mime text,p_size bigint,p_thumb_url text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; e public.subject_diary_entries%rowtype; result uuid;
begin
 select * into o from private.chat_file_objects where file_key=p_yandex_key for update;
 if not found or auth.uid() is null or o.uploaded_by<>auth.uid() or not o.confirmed or o.file_id is not null
   or o.delete_requested_at is not null or o.deleted_at is not null then raise exception 'untrusted_upload' using errcode='42501';end if;
 select * into e from public.subject_diary_entries where id=p_entry_id and author_id=auth.uid() for update;
 if not found then raise exception 'forbidden' using errcode='42501';end if;
 if o.diary_file_id is not null then
  if exists(select 1 from public.subject_diary_files where id=o.diary_file_id and entry_id=p_entry_id) then return o.diary_file_id;end if;
  raise exception 'already_attached' using errcode='42501';
 end if;
 if o.expires_at<=now() or not exists(select 1 from public.chats where id=o.chat_id and team_id=e.team_id)
 then raise exception 'invalid_diary_upload' using errcode='42501';end if;
 insert into public.subject_diary_files(entry_id,uploaded_by,yandex_key,file_url,mime,size_bytes,thumb_url)
 values(e.id,auth.uid(),o.file_key,o.file_url,o.file_type,o.file_size,null) returning id into result;
 update private.chat_file_objects set diary_file_id=result where file_key=p_yandex_key;
 return result;
end $$;
revoke all on function public.add_subject_diary_file(uuid,text,text,text,bigint,text) from public,anon;
grant execute on function public.add_subject_diary_file(uuid,text,text,text,bigint,text) to authenticated;
revoke insert,update on public.subject_diary_files from public,anon,authenticated;
revoke insert(id,entry_id,uploaded_by,yandex_key,file_url,mime,size_bytes,thumb_url,created_at),update(id,entry_id,uploaded_by,yandex_key,file_url,mime,size_bytes,thumb_url,created_at) on public.subject_diary_files from public,anon,authenticated;

create or replace function public.save_chat_file(p_chat_id uuid,p_file_name text,p_file_key text,p_file_url text,p_file_type text,p_file_size bigint,p_uploaded_by uuid default null,p_message_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; result uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  select * into o from private.chat_file_objects where file_key=p_file_key for update;
  if not found or o.uploaded_by<>auth.uid() or o.diary_file_id is not null or o.chat_id<>p_chat_id or not o.confirmed or o.delete_requested_at is not null
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

create or replace function public.discard_unattached_chat_upload(p_key text) returns boolean
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; f public.chat_files%rowtype;
begin
  select * into o from private.chat_file_objects where file_key=p_key and uploaded_by=auth.uid() for update;
  if not found then raise exception 'forbidden' using errcode='42501'; end if;
  if o.diary_file_id is not null then return false; end if;
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


create or replace function public.claim_chat_upload_cleanup(p_limit integer default 20) returns table(file_key text)
language plpgsql security definer set search_path='' as $$
declare o private.chat_file_objects%rowtype; f public.chat_files%rowtype;
begin
  if auth.jwt()->>'role' is distinct from 'service_role' then raise exception 'forbidden' using errcode='42501'; end if;
  for o in select x.* from private.chat_file_objects x where x.expires_at<now() and x.deleted_at is null and x.diary_file_id is null
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
