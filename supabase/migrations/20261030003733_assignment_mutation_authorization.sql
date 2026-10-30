-- Guard legacy SECURITY DEFINER mutations without changing the client contract.
create or replace function public.remove_assignment(p_assignment_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_row public.assignments; v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'forbidden' using errcode='42501'; end if;
  select * into v_row from public.assignments where id=p_assignment_id for update;
  if not found or not private.is_active_team_member(v_row.team_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if coalesce(v_row.author_id,v_row.created_by) is distinct from v_user
    and not exists(select 1 from public.team_members where team_id=v_row.team_id
      and user_id=v_user and lower(coalesce(role,'')) in ('owner','starosta','teacher','admin')) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  delete from public.assignments where id=p_assignment_id;
end $$;

create or replace function public.update_assignment(p_assignment_id uuid,p_title text,p_description text,p_link text,p_due text,p_attachments jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_row public.assignments; v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'forbidden' using errcode='42501'; end if;
  select * into v_row from public.assignments where id=p_assignment_id for update;
  if not found or not private.is_active_team_member(v_row.team_id) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if coalesce(v_row.author_id,v_row.created_by) is distinct from v_user
    and not exists(select 1 from public.team_members where team_id=v_row.team_id
      and user_id=v_user and lower(coalesce(role,'')) in ('owner','starosta','teacher','admin')) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  update public.assignments set
    title=coalesce(nullif(p_title,''),title),
    description=coalesce(nullif(p_description,''),description),
    link=nullif(p_link,''),due_text=nullif(p_due,''),
    attachments=coalesce(p_attachments,'[]'::jsonb)
  where id=p_assignment_id;
end $$;

create or replace function public.set_assignment_done(p_assignment_id uuid,p_done boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_row public.assignments; v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'forbidden' using errcode='42501'; end if;
  select * into v_row from public.assignments where id=p_assignment_id for update;
  if not found or not private.is_active_team_member(v_row.team_id)
    or (v_row.status is distinct from 'published' and v_row.published_at is null) then
    raise exception 'forbidden' using errcode='42501';
  end if;
  if p_done then
    insert into public.assignment_done(assignment_id,user_id) values(p_assignment_id,v_user)
    on conflict(assignment_id,user_id) do nothing;
    return true;
  end if;
  delete from public.assignment_done where assignment_id=p_assignment_id and user_id=v_user;
  return false;
end $$;

revoke all on function public.remove_assignment(uuid) from public,anon;
revoke all on function public.update_assignment(uuid,text,text,text,text,jsonb) from public,anon;
revoke all on function public.set_assignment_done(uuid,boolean) from public,anon;
grant execute on function public.remove_assignment(uuid) to authenticated;
grant execute on function public.update_assignment(uuid,text,text,text,text,jsonb) to authenticated;
grant execute on function public.set_assignment_done(uuid,boolean) to authenticated;
