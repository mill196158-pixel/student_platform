create or replace function public.set_assignment_done(p_assignment_id uuid, p_done boolean)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_assignment public.assignments;
  v_user uuid := auth.uid();
  v_has_done boolean;
  v_has_done_at boolean;
begin
  if v_user is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_assignment from public.assignments where id = p_assignment_id for update;
  if not found or not private.is_active_team_member(v_assignment.team_id)
    or (v_assignment.status is distinct from 'published' and v_assignment.published_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_done is not true then
    delete from public.assignment_done where assignment_id = p_assignment_id and user_id = v_user;
    return false;
  end if;

  -- Some installations store just the two keys. Older installations expose
  -- a boolean and may also record when the student completed the assignment.
  select bool_or(attname = 'done'), bool_or(attname = 'done_at')
    into v_has_done, v_has_done_at
    from pg_catalog.pg_attribute
    where attrelid = 'public.assignment_done'::regclass and attnum > 0 and not attisdropped;
  if v_has_done and v_has_done_at then
    insert into public.assignment_done as receipt(assignment_id, user_id, done, done_at)
      values (p_assignment_id, v_user, true, now())
      on conflict (assignment_id, user_id) do update
        set done = true, done_at = excluded.done_at where receipt.done is false;
  elsif v_has_done then
    insert into public.assignment_done as receipt(assignment_id, user_id, done)
      values (p_assignment_id, v_user, true)
      on conflict (assignment_id, user_id) do update set done = true where receipt.done is false;
  else
    insert into public.assignment_done(assignment_id, user_id)
      values (p_assignment_id, v_user) on conflict (assignment_id, user_id) do nothing;
  end if;
  return true;
end $$;

revoke all on function public.set_assignment_done(uuid, boolean) from public, anon;
grant execute on function public.set_assignment_done(uuid, boolean) to authenticated;
