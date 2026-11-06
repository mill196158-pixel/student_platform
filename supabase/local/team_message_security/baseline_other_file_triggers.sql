-- Production file trigger definitions, read-only snapshot for local tests.
CREATE OR REPLACE FUNCTION public.trg_fn_block_archived_academic_chat_file_writes()
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

CREATE OR REPLACE FUNCTION private.chat_files_protect_sensitive_flag()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'UPDATE'
     and old.is_sensitive is true
     and coalesce(new.is_sensitive, false) is distinct from true then
    if coalesce(current_setting('private.allow_sensitive_clear', true), '') <> '1' then
      raise exception 'sensitive_flag_immutable' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$function$;

create trigger trg_chat_files_block_archived_academic before insert or delete or update on public.chat_files for each row execute function public.trg_fn_block_archived_academic_chat_file_writes();
create trigger trg_chat_files_protect_sensitive_flag before update on public.chat_files for each row execute function private.chat_files_protect_sensitive_flag();

