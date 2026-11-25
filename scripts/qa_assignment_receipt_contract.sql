-- qa_local_academic_diary.py supplies an isolated schema and rolls back this transaction.
do $$
begin
  if not exists (
    select 1 from original_proc b join pg_proc p using (oid)
    where b.proowner = p.proowner and b.proacl is not distinct from p.proacl
      and b.prosecdef = p.prosecdef and b.proconfig is not distinct from p.proconfig
  ) or has_function_privilege('anon', 'set_assignment_done(uuid,boolean)', 'EXECUTE')
    or not has_function_privilege('authenticated', 'set_assignment_done(uuid,boolean)', 'EXECUTE') then
    raise exception 'Assignment RPC identity, grants or execution properties changed';
  end if;
end $$;

create procedure pg_temp.check_receipt_lifecycle() language plpgsql as $$
declare
  target uuid := (select id from assignments where title = 'Legacy practice');
  owner_id uuid := current_setting('qa.student')::uuid;
  peer_id uuid := current_setting('qa.peer')::uuid;
  row_data jsonb;
begin
  perform set_config('request.jwt.claim.sub', peer_id::text, true);
  if set_assignment_done(target, true) is not true then raise exception 'Peer write failed'; end if;
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  if set_assignment_done(target, true) is not true then raise exception 'Owner write failed'; end if;
  select to_jsonb(d) into strict row_data from assignment_done d
    where assignment_id = target and user_id = owner_id;
  if row_data ? 'done' and row_data->>'done' is distinct from 'true' then
    raise exception 'Existing explicit false was not completed';
  end if;
  if row_data ? 'done_at' then
    if row_data->>'done_at' is null or (row_data->>'done_at')::timestamptz < transaction_timestamp() then
      raise exception 'Historic false did not receive its completion time';
    end if;
    -- A historical completion must not receive a new date on an idempotent retry.
    update assignment_done set done_at = '2002-02-03T01:00:00Z'
      where assignment_id = target and user_id = owner_id;
    select to_jsonb(d) into strict row_data from assignment_done d
      where assignment_id = target and user_id = owner_id;
  end if;
  if set_assignment_done(target, true) is not true then raise exception 'Retry failed'; end if;
  if not exists (select 1 from assignment_done d where to_jsonb(d) = row_data)
    or (select count(*) from assignment_done where assignment_id = target) <> 2 then
    raise exception 'Retry changed an existing completion or its peer';
  end if;
  if set_assignment_done(target, false) is not false then raise exception 'Undo failed'; end if;
  if exists (select 1 from assignment_done where assignment_id = target and user_id = owner_id)
    or not exists (select 1 from assignment_done where assignment_id = target and user_id = peer_id) then
    raise exception 'Undo did not affect only the owner';
  end if;
  perform set_config('request.jwt.claim.sub', peer_id::text, true);
  perform set_assignment_done(target,false);
end $$;

-- With an explicit boolean, the fixture already contains the owner's old false.
call pg_temp.check_receipt_lifecycle();

-- A compact deployment has neither of the optional columns.
alter table assignment_done drop column done;
call pg_temp.check_receipt_lifecycle();

-- Rehearse the four-column version recorded by the historical schema audit.
alter table assignment_done add column done boolean default false, add column done_at timestamptz;
insert into assignment_done(assignment_id,user_id,done,done_at)
  select id,current_setting('qa.student')::uuid,false,'2001-01-01Z'
  from assignments where title = 'Legacy practice';
call pg_temp.check_receipt_lifecycle();
