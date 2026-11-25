-- Local QA baseline of the ordinary chat read and send RPCs, captured 2026-11-25.
-- Installed only by the opt-in local test schema runner.
CREATE OR REPLACE FUNCTION public.get_unread_in_chat(p_chat_id uuid)
 RETURNS TABLE(unread_count integer, first_unread_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with last as (
    select cr.last_read_at
    from public.chat_reads cr
    where cr.chat_id = p_chat_id
      and cr.user_id = auth.uid()
    limit 1
  ),
  unread as (
    select m.id, m.created_at
    from public.messages m
    where m.chat_id = p_chat_id
      and m.author_id <> auth.uid()
      and m.created_at > coalesce((select last_read_at from last), to_timestamp(0))
  )
  select
    coalesce((select count(*) from unread), 0)::int as unread_count,
    (select id from unread order by created_at asc limit 1) as first_unread_id;
$function$;
CREATE OR REPLACE FUNCTION public.mark_chat_read(p_chat_id uuid, p_message_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_msg_at timestamptz;
  v_new_last_at timestamptz;
begin
  if p_message_id is not null then
    select created_at into v_msg_at from public.messages where id = p_message_id;
  end if;

  v_new_last_at := coalesce(v_msg_at, now());

  insert into public.chat_reads(chat_id, user_id, last_read_at, last_read_message_id)
  values (p_chat_id, auth.uid(), v_new_last_at, p_message_id)
  on conflict (chat_id, user_id) do update
    set last_read_at    = greatest(chat_reads.last_read_at, excluded.last_read_at),
        last_read_message_id = coalesce(excluded.last_read_message_id, chat_reads.last_read_message_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.send_chat_message(p_team_id uuid, p_text text, p_type text DEFAULT 'text'::text, p_reply_to uuid DEFAULT NULL::uuid, p_attachment_url text DEFAULT NULL::text, p_assignment_id uuid DEFAULT NULL::uuid, p_file_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_chat_id uuid;
  v_author_id uuid;
  v_attachments jsonb;
  v_message_id uuid;
BEGIN
  v_author_id := auth.uid();
  IF v_author_id IS NULL THEN
    RAISE EXCEPTION 'auth.uid() is null';
  END IF;

  PERFORM 1 FROM public.team_members tm
    WHERE tm.team_id = p_team_id AND tm.user_id = v_author_id
    FOR KEY SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_chat_id FROM public.chats
  WHERE team_id = p_team_id AND type = 'team_main' LIMIT 1;

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'Chat not found for team %', p_team_id;
  END IF;

  IF p_attachment_url IS NULL OR length(trim(p_attachment_url)) = 0 THEN
    v_attachments := '[]'::jsonb;
  ELSE
    v_attachments := to_jsonb(array[p_attachment_url]);
  END IF;

  -- Вставляем сообщение и получаем его ID
  INSERT INTO public.messages(
    chat_id, author_id, content, body, msg_type, reply_to_id, attachments, assignment_id, created_at
  ) VALUES (
    v_chat_id, v_author_id, coalesce(p_text,''), coalesce(p_text,''),
    coalesce(p_type,'text'), p_reply_to, v_attachments, p_assignment_id, now()
  ) RETURNING id INTO v_message_id;

  -- Если передан file_id, обновляем chat_files
  IF p_file_id IS NOT NULL THEN
    UPDATE public.chat_files
    SET message_id = v_message_id
    WHERE id = p_file_id;
  END IF;

  RETURN v_message_id;
END; $function$;

revoke all on function public.get_unread_in_chat(uuid), public.mark_chat_read(uuid,uuid),
  public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid) from public, anon;
grant execute on function public.get_unread_in_chat(uuid), public.mark_chat_read(uuid,uuid),
  public.send_chat_message(uuid,text,text,uuid,text,uuid,uuid) to authenticated;
