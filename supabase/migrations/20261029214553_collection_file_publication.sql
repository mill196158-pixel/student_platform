create table private.collection_publications (
  actor_id uuid not null references auth.users(id) on delete cascade,
  client_key uuid not null,
  payload jsonb not null,
  collection_id uuid not null references public.group_collections(id) on delete cascade,
  primary key(actor_id,client_key)
);
alter table private.collection_publications enable row level security;
alter table private.collection_publications force row level security;
revoke all on private.collection_publications from public,anon,authenticated;

create function public.get_collection_upload_context() returns uuid
language plpgsql stable security definer set search_path='' as $$
declare team uuid:=private.group_space_team_id(private.current_active_group_id()); chat uuid;
begin
  if auth.uid() is null or team is null or not private.can_create_team_collections(team)
  then raise exception 'forbidden' using errcode='42501'; end if;
  chat:=private.team_main_chat_id(team);
  if chat is null or exists(select 1 from public.chat_academic_archives where chat_id=chat and expired_at is not null)
  then raise exception 'chat_unavailable' using errcode='42501'; end if;
  return chat;
end $$;
revoke all on function public.get_collection_upload_context() from public,anon;
grant execute on function public.get_collection_upload_context() to authenticated;

create function public.create_group_collection_with_files(
  p_client_key uuid,p_title text,p_description text default '',p_purpose text default '',
  p_deadline_at timestamptz default null,p_amount_optional numeric default null,
  p_instructions text default '',p_payment_details text default '',p_amount_mode text default 'none',
  p_amount_total numeric default null,p_file_ids uuid[] default '{}'
) returns uuid language plpgsql security definer set search_path='' as $$
declare chat uuid; payload jsonb; previous private.collection_publications%rowtype;
  result uuid; message uuid; count_valid integer;
begin
  if auth.uid() is null or p_client_key is null then raise exception 'not_authenticated' using errcode='42501'; end if;
  chat:=public.get_collection_upload_context();
  payload:=jsonb_build_object('chat',chat,'title',p_title,'description',p_description,'purpose',p_purpose,
    'deadline',p_deadline_at,'per',p_amount_optional,'instructions',p_instructions,'payment',p_payment_details,
    'mode',p_amount_mode,'total',p_amount_total,'files',coalesce(p_file_ids,'{}'));
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_client_key::text,0));
  select * into previous from private.collection_publications where actor_id=auth.uid() and client_key=p_client_key;
  if found then
    if previous.payload<>payload then raise exception 'publication_key_reused' using errcode='22023'; end if;
    return previous.collection_id;
  end if;
  if cardinality(coalesce(p_file_ids,'{}'))>10 or cardinality(coalesce(p_file_ids,'{}'))<>(select count(distinct x) from unnest(p_file_ids) x)
  then raise exception 'invalid_files' using errcode='22023'; end if;
  -- Lock in stable order; deletion/cleanup and publication must use these rows.
  perform 1 from public.chat_files where id=any(p_file_ids) order by id for update;
  select count(*) into count_valid from public.chat_files f join private.chat_file_objects o on o.file_id=f.id
    where f.id=any(p_file_ids) and f.chat_id=chat and f.uploaded_by=auth.uid() and f.message_id is null
      and not coalesce(f.is_deleted,false) and not coalesce(f.is_sensitive,false)
      and o.confirmed and o.delete_requested_at is null and o.deleted_at is null and o.chat_id=f.chat_id and o.uploaded_by=f.uploaded_by and o.file_key=f.file_key
      and not exists(select 1 from public.group_collection_contributions where proof_file_id=f.id);
  if count_valid<>cardinality(coalesce(p_file_ids,'{}')) then raise exception 'invalid_files' using errcode='42501'; end if;
  result:=public.create_group_collection(p_title,p_description,p_purpose,p_deadline_at,p_amount_optional,p_instructions,p_payment_details,p_amount_mode,p_amount_total);
  select card_message_id into message from public.group_collections where id=result;
  if message is null then raise exception 'card_message_missing'; end if;
  update public.chat_files set message_id=message where id=any(p_file_ids);
  insert into private.collection_publications values(auth.uid(),p_client_key,payload,result);
  return result;
end $$;
revoke all on function public.create_group_collection_with_files(uuid,text,text,text,timestamptz,numeric,text,text,text,numeric,uuid[]) from public,anon;
grant execute on function public.create_group_collection_with_files(uuid,text,text,text,timestamptz,numeric,text,text,text,numeric,uuid[]) to authenticated;
