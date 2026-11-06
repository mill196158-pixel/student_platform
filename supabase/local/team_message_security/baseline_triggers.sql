-- Read-only snapshot of production trigger functions, local tests only.
-- Other production triggers (notifications/metrics) are not represented.
CREATE OR REPLACE FUNCTION private.guard_chat_file_message_binding()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION private.guard_chat_file_reference()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.assert_academic_chat_writable(p_chat_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- service_role may perform system maintenance
  if coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    return;
  end if;

  if public.is_academic_chat_read_only(p_chat_id) then
    raise exception using
      errcode = 'P0001',
      message = 'academic_chat_archived';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.fn_messages_block_dm_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := (select auth.uid());
  v_chat_type text;
  v_peer uuid;
begin
  -- Preserve service-role / non-user server operations.
  if v_me is null then
    return new;
  end if;

  if new.author_id is distinct from v_me then
    raise exception using
      errcode = 'P0001',
      message = 'not_author';
  end if;

  if new.chat_id is null then
    return new;
  end if;

  select c.type
  into v_chat_type
  from public.chats c
  where c.id = new.chat_id;

  if v_chat_type is distinct from 'dm' then
    return new;
  end if;

  select cm.user_id
  into v_peer
  from public.chat_members cm
  where cm.chat_id = new.chat_id
    and cm.user_id <> v_me
  limit 1;

  if v_peer is null then
    return new;
  end if;

  if exists (
    select 1
    from public.user_blocks ub
    where (ub.blocker_id = v_me and ub.blocked_id = v_peer)
       or (ub.blocker_id = v_peer and ub.blocked_id = v_me)
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'dm_blocked';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.is_academic_chat_read_only(p_chat_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- Any archive row (including expired) stays permanently read-only.
  select exists (
    select 1
    from public.chat_academic_archives a
    where a.chat_id = p_chat_id
  );
$function$;

CREATE OR REPLACE FUNCTION public.trg_fn_block_archived_academic_message_writes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_chat_id uuid;
begin
  if coalesce((select auth.jwt() ->> 'role'), '') = 'service_role' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_chat_id := old.chat_id;
  else
    v_chat_id := new.chat_id;
  end if;

  perform public.assert_academic_chat_writable(v_chat_id);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.team_main_chat_id(p_team_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.id
  from public.chats c
  where c.team_id = p_team_id and c.type = 'team_main'
  limit 1;
$function$;
create trigger guard_collection_proof before insert or update of proof_file_id on public.group_collection_contributions for each row execute function private.guard_chat_file_reference('proof_file_id','proof');
create trigger guard_chat_file_message_binding before insert or update of message_id on public.chat_files for each row execute function private.guard_chat_file_message_binding();
create trigger guard_message_file before insert or update of file_id on public.messages for each row execute function private.guard_chat_file_reference('file_id','normal');
create trigger trg_messages_block_archived_academic before insert or delete or update on public.messages for each row execute function public.trg_fn_block_archived_academic_message_writes();
create trigger trg_messages_block_dm_insert before insert on public.messages for each row execute function public.fn_messages_block_dm_insert();
revoke all on function private.guard_chat_file_message_binding() from public, anon, authenticated;
revoke all on function private.guard_chat_file_reference() from public, anon, authenticated;

