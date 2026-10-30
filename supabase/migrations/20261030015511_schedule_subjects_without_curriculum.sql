-- No-plan schedule provisioning. Does not backfill existing production rows.
create extension if not exists pg_trgm with schema extensions;

create or replace function private.sync_schedule_subjects(
  p_group_id uuid, p_from date, p_to date, p_dry_run boolean default true,
  p_normalized_name text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r record; v_term record; v_group text; v_norm text; v_subject uuid;
  v_offering uuid; v_team uuid; v_ids uuid[]; v_count integer;
  v_sem integer; v_admission integer; v_plan boolean; v_reason text;
  v_linked integer := 0; v_created integer := 0; v_offerings integer := 0;
  v_teams integer := 0; v_pending integer := 0; v_details jsonb := '[]';
begin
  if p_dry_run is null or p_group_id is null or p_from is null or p_to is null or p_to < p_from
     or p_to - p_from > 370 then
    raise exception 'invalid_schedule_subject_scope' using errcode='22023';
  end if;
  select name into v_group from public.groups where id=p_group_id;
  if not found then raise exception 'group_not_found' using errcode='P0002'; end if;
  -- Same lock is taken before import DELETE/INSERT. One order for all groups,
  -- including cross-group creation of the same canonical subject.
  if not p_dry_run then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('schedule-subject-provision-v1',0));
  end if;
  for r in select l.* from public.lessons l
    where l.group_id=p_group_id and l.date between p_from and p_to
      and (p_normalized_name is null or public.f_norm_schedule_subject(coalesce(nullif(l.raw_subject_name,''),l.subject))=p_normalized_name)
    order by l.date, l.id
  loop
    v_reason := null; v_subject := null; v_offering := null; v_team := null;
    v_sem := null; v_admission := null; v_ids := null;
    v_norm := public.f_norm_schedule_subject(coalesce(nullif(r.raw_subject_name,''),r.subject));
    select count(*) into v_count from public.academic_terms t where r.date between t.starts_on and t.ends_on;
    if v_count <> 1 then
      v_reason := case when v_count=0 then 'no_term' else 'ambiguous_term' end;
    else
      select t.*, y.start_year into v_term from public.academic_terms t
        join public.academic_years y on y.id=t.academic_year_id
        where r.date between t.starts_on and t.ends_on;
      select semester_number into v_sem from public.group_term_semesters
        where group_id=p_group_id and academic_term_id=v_term.id;
      select coalesce(i.admission_year,gap.admission_year) into v_admission
        from public.groups g left join public.group_academic_identities i on i.group_id=g.id
        left join public.group_academic_profiles gap on gap.group_id=g.id and gap.active
        where g.id=p_group_id;
      if exists(select 1 from public.group_academic_identities i
          join public.group_academic_profiles gap on gap.group_id=i.group_id and gap.active
          where i.group_id=p_group_id and i.admission_year<>gap.admission_year) then
        v_reason := 'conflicting_admission_year';
      end if;
      v_sem := coalesce(v_sem, r.semester_number,
        (v_term.start_year-v_admission)*2+v_term.term_in_year);
      if v_sem is null or v_sem not between 1 and 20 then v_reason := 'no_semester'; end if;
      if r.semester_number is not null and r.semester_number<>v_sem then
        v_reason := 'conflicting_semester';
      end if;
    end if;
    if nullif(v_norm,'') is null then v_reason := 'empty_name'; end if;

    if v_reason is null then
      select exists(select 1 from public.group_academic_profiles gap
        join public.curriculum_plans cp on cp.id=gap.curriculum_plan_id
        where gap.group_id=p_group_id and gap.active
          and cp.status in ('reviewed','active') and cp.reviewed_at is not null
          and cp.admission_year=gap.admission_year
          and v_sem between 1 and cp.nominal_semesters) into v_plan;

      select array_agg(distinct sc.id) into v_ids from public.subject_catalog sc
        left join public.subject_aliases a on a.subject_id=sc.id
        where public.f_norm_schedule_subject(sc.canonical_name)=v_norm
          or public.f_norm_schedule_subject(sc.normalized_name)=v_norm
          or public.f_norm_schedule_subject(a.alias)=v_norm
          or public.f_norm_schedule_subject(a.normalized_alias)=v_norm;
      if coalesce(cardinality(v_ids),0)>1 then v_reason := 'ambiguous_subject';
      elsif cardinality(v_ids)=1 then
        v_subject := v_ids[1];
        if exists(select 1 from public.subject_catalog where id=v_subject and status='archived') then
          v_reason := 'archived_subject';
        end if;
      elsif v_plan then v_reason := 'subject_not_in_plan';
      elsif exists(select 1 from public.subject_catalog sc
        where extensions.similarity(public.f_norm_schedule_subject(sc.canonical_name),v_norm)>=0.65)
        or exists(select 1 from public.subject_aliases a
        where extensions.similarity(public.f_norm_schedule_subject(a.alias),v_norm)>=0.65) then
        v_reason := 'review_similar_name';
      end if;

      -- Preserve an authoritative existing binding; never silently change it.
      if r.subject_offering_id is not null then
        if not exists(select 1 from public.subject_offerings so where so.id=r.subject_offering_id
            and so.group_id=p_group_id and so.academic_term_id=v_term.id
            and so.semester_number=v_sem and so.subject_id=v_subject and so.status<>'cancelled') then
          v_reason := 'existing_binding_conflict';
        end if;
      end if;
      if v_reason is null and v_subject is not null then
        select array_agg(id) into v_ids from public.subject_offerings
          where group_id=p_group_id and subject_id=v_subject and academic_term_id=v_term.id
            and semester_number=v_sem and status<>'cancelled';
        if cardinality(v_ids)>1 then v_reason := 'ambiguous_offering';
        elsif cardinality(v_ids)=1 then v_offering := v_ids[1];
        elsif v_plan then v_reason := 'plan_offering_missing';
        elsif exists(select 1 from public.subject_offerings where group_id=p_group_id
            and subject_id=v_subject and academic_term_id=v_term.id) then
          v_reason := 'offering_conflict';
        end if;
      end if;
      if v_reason is null and v_term.is_current then
        if v_offering is not null then
          select id into v_team from public.teams where subject_offering_id=v_offering;
          if v_team is not null and not exists(select 1 from public.teams where id=v_team
              and group_id=p_group_id and subject_id=v_subject and academic_term_id=v_term.id and kind='subject') then
            v_reason := 'team_binding_conflict';
          elsif v_team is not null and exists(select 1 from public.chats c
              join public.chat_academic_archives a on a.chat_id=c.id where c.team_id=v_team) then
            v_reason := 'archived_team';
          end if;
        end if;
        if v_team is null and exists(select 1 from public.teams t
          where (t.group_id=p_group_id or (t.group_id is null and t.group_name=v_group))
            and t.subject_offering_id is null and t.kind='subject'
            and public.f_norm_schedule_subject(t.name)=v_norm) then
          v_reason := 'legacy_team_requires_review';
        end if;
      end if;
    end if;

    if v_reason is not null then
      v_pending := v_pending+1;
      v_details := v_details || jsonb_build_array(jsonb_build_object('lesson_id',r.id,'raw',r.subject,'reason',v_reason));
      if not p_dry_run and r.subject_offering_id is null then
        update public.lessons set normalized_subject_name=v_norm,
          alias_match_status=case when v_reason in ('ambiguous_subject','ambiguous_offering','review_similar_name') then 'ambiguous' else 'pending' end
          where id=r.id and (normalized_subject_name is distinct from v_norm or alias_match_status is distinct from
            case when v_reason in ('ambiguous_subject','ambiguous_offering','review_similar_name') then 'ambiguous' else 'pending' end);
      end if;
      continue;
    end if;
    if p_dry_run then v_linked:=v_linked+1; continue; end if;
    if v_subject is null then
      insert into public.subject_catalog(canonical_name,normalized_name)
        values(public.f_subject_base(r.subject),v_norm)
        on conflict(normalized_name) do nothing returning id into v_subject;
      if v_subject is not null then v_created:=v_created+1;
      else select id into v_subject from public.subject_catalog where normalized_name=v_norm; end if;
    end if;
    insert into public.group_term_semesters(group_id,academic_term_id,academic_year_id,semester_number)
      values(p_group_id,v_term.id,v_term.academic_year_id,v_sem) on conflict(group_id,academic_term_id) do nothing;
    if not exists(select 1 from public.group_term_semesters where group_id=p_group_id
        and academic_term_id=v_term.id and semester_number=v_sem and academic_year_id=v_term.academic_year_id) then
      raise exception 'concurrent_semester_conflict' using errcode='40001';
    end if;
    if v_offering is null then
      insert into public.subject_offerings(subject_id,group_id,academic_year_id,academic_term_id,semester_number,display_name)
        select v_subject,p_group_id,v_term.academic_year_id,v_term.id,v_sem,canonical_name
        from public.subject_catalog where id=v_subject
        on conflict(group_id,subject_id,academic_year_id,academic_term_id) where curriculum_subject_id is null
        do nothing returning id into v_offering;
      if v_offering is not null then v_offerings:=v_offerings+1;
      else select id into v_offering from public.subject_offerings where group_id=p_group_id
        and subject_id=v_subject and academic_term_id=v_term.id and curriculum_subject_id is null; end if;
    end if;
    if not exists(select 1 from public.subject_offerings where id=v_offering
        and group_id=p_group_id and subject_id=v_subject and academic_term_id=v_term.id
        and academic_year_id=v_term.academic_year_id and semester_number=v_sem and status<>'cancelled') then
      raise exception 'concurrent_offering_conflict' using errcode='40001';
    end if;
    if v_term.is_current then
      if v_team is null then
        -- group_id is authoritative. NULL legacy display-group avoids the old
        -- cross-semester unique(group_name, normalized team name) constraint.
        insert into public.teams(name,group_name,group_id,subject_id,subject_offering_id,
          academic_year_id,academic_term_id,semester_number,kind,icon)
          select canonical_name,null,p_group_id,v_subject,v_offering,v_term.academic_year_id,v_term.id,v_sem,'subject','📘'
          from public.subject_catalog where id=v_subject
          on conflict(subject_offering_id) where subject_offering_id is not null do nothing returning id into v_team;
        if v_team is not null then v_teams:=v_teams+1;
        else select id into v_team from public.teams where subject_offering_id=v_offering; end if;
      end if;
      if not exists(select 1 from public.teams where id=v_team and subject_offering_id=v_offering
          and group_id=p_group_id and subject_id=v_subject and academic_term_id=v_term.id
          and academic_year_id=v_term.academic_year_id and semester_number=v_sem and kind='subject')
          or exists(select 1 from public.chats c join public.chat_academic_archives a on a.chat_id=c.id where c.team_id=v_team) then
        raise exception 'concurrent_team_conflict' using errcode='40001';
      end if;
      perform private.stage13_8_ensure_subject_chat_and_members(v_team);
    end if;
    update public.lessons set subject_id=v_subject,subject_offering_id=v_offering,
      academic_year_id=v_term.academic_year_id,academic_term_id=v_term.id,
      semester_number=v_sem,normalized_subject_name=v_norm,alias_match_status='matched'
      where id=r.id and (subject_offering_id is distinct from v_offering or alias_match_status<>'matched'
        or academic_term_id is distinct from v_term.id or semester_number is distinct from v_sem);
    v_linked:=v_linked+1;
  end loop;
  return jsonb_build_object('group_id',p_group_id,'dry_run',p_dry_run,'linked',v_linked,
    'created_subjects',v_created,'created_offerings',v_offerings,'created_teams',v_teams,
    'pending',v_pending,'issues',v_details);
end $$;
revoke all on function private.sync_schedule_subjects(uuid,date,date,boolean,text) from public,anon,authenticated;

create or replace function public.admin_sync_schedule_subjects(
  p_group_id uuid,p_from date,p_to date,p_dry_run boolean default true
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform private.rasp_schedule_require_run();
  return private.sync_schedule_subjects(p_group_id,p_from,p_to,p_dry_run);
end $$;
revoke all on function public.admin_sync_schedule_subjects(uuid,date,date,boolean) from public,anon;
grant execute on function public.admin_sync_schedule_subjects(uuid,date,date,boolean) to authenticated,service_role;

-- Explicit human resolution is available without a curriculum plan.
create or replace function public.admin_list_unlinked_schedule_subjects()
returns table(group_id uuid,group_name text,raw_subject text,lesson_count bigint,first_date date,last_date date)
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null or not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  return query select l.group_id,g.name,coalesce(nullif(l.raw_subject_name,''),l.subject),count(*),min(l.date),max(l.date)
    from public.lessons l join public.groups g on g.id=l.group_id
    where l.subject_offering_id is null
    group by l.group_id,g.name,coalesce(nullif(l.raw_subject_name,''),l.subject)
    order by g.name,coalesce(nullif(l.raw_subject_name,''),l.subject);
end $$;
revoke all on function public.admin_list_unlinked_schedule_subjects() from public,anon;
grant execute on function public.admin_list_unlinked_schedule_subjects() to authenticated;

create or replace function public.admin_bind_schedule_subject(p_group_id uuid,p_raw_subject text,p_subject_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_norm text; r record; v_result jsonb := '[]';
begin
  if auth.uid() is null or not private.academic_ingestion_has_permission('subjects.write') then
    raise exception 'forbidden' using errcode='42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('schedule-subject-provision-v1',0));
  v_norm:=public.f_norm_schedule_subject(p_raw_subject);
  if nullif(v_norm,'') is null or not exists(select 1 from public.lessons l where l.group_id=p_group_id
      and public.f_norm_schedule_subject(coalesce(nullif(l.raw_subject_name,''),l.subject))=v_norm) then
    raise exception 'schedule_name_not_found' using errcode='22023';
  end if;
  if not exists(select 1 from public.subject_catalog where id=p_subject_id and status<>'archived') then
    raise exception 'subject_not_available' using errcode='22023';
  end if;
  if exists(select 1 from public.subject_catalog sc where sc.id<>p_subject_id
      and (public.f_norm_schedule_subject(sc.canonical_name)=v_norm or public.f_norm_schedule_subject(sc.normalized_name)=v_norm))
    or exists(select 1 from public.subject_aliases a where a.subject_id<>p_subject_id
      and (public.f_norm_schedule_subject(a.alias)=v_norm or public.f_norm_schedule_subject(a.normalized_alias)=v_norm)) then
    raise exception 'name_belongs_to_another_subject' using errcode='23505';
  end if;
  insert into public.subject_aliases(subject_id,alias,normalized_alias,source)
    values(p_subject_id,p_raw_subject,v_norm,'schedule_review')
    on conflict(normalized_alias) do nothing;
  if not exists(select 1 from public.subject_aliases where normalized_alias=v_norm and subject_id=p_subject_id) then
    raise exception 'concurrent_alias_conflict' using errcode='40001';
  end if;
  for r in select min(l.date) first_date,max(l.date) last_date from public.lessons l
      where l.group_id=p_group_id and public.f_norm_schedule_subject(coalesce(nullif(l.raw_subject_name,''),l.subject))=v_norm
      group by extract(year from l.date)
  loop
    v_result:=v_result||jsonb_build_array(private.sync_schedule_subjects(p_group_id,r.first_date,r.last_date,false,v_norm));
  end loop;
  perform private.admin_write_audit('schedule_subject.bind','group',p_group_id::text,
    jsonb_build_object('raw',p_raw_subject,'subject_id',p_subject_id,'result',v_result));
  return jsonb_build_object('subject_sync',v_result);
end $$;
revoke all on function public.admin_bind_schedule_subject(uuid,text,uuid) from public,anon;
grant execute on function public.admin_bind_schedule_subject(uuid,text,uuid) to authenticated;

-- Integrate once per imported group, preserving existing admission-year validation.
CREATE OR REPLACE FUNCTION public.admin_save_rasp_schedule_run(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_run_id uuid;
  v_subject_sync jsonb := '[]'::jsonb;
  v_row jsonb;
  v_status text;
  v_error text;
  v_lessons jsonb;
  v_group uuid;
  v_min date;
  v_max date;
  v_lesson jsonb;
  v_applied integer := 0;
  v_skipped integer := 0;
  v_fetched integer := 0;
  v_count integer := 0;
  v_db_year integer;
  v_db_name text;
  v_starts integer[];
  v_site_names text[];
  v_site_name text;
  v_parsed jsonb;
  v_derived integer;
  v_year_error text;
begin
  perform private.rasp_schedule_require_run();
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('schedule-subject-provision-v1',0));
  if jsonb_typeof(coalesce(p_payload -> 'groups', '[]'::jsonb)) <> 'array' then
    raise exception 'invalid_rasp_schedule_payload' using errcode = '22023';
  end if;

  insert into public.rasp_schedule_runs(
    trigger, created_by, started_at
  ) values (
    case when p_payload ->> 'trigger' = 'cron' then 'cron' else 'manual' end,
    auth.uid(),
    now()
  )
  returning id into v_run_id;

  for v_row in select value from jsonb_array_elements(p_payload -> 'groups')
  loop
    v_count := v_count + 1;
    v_status := coalesce(v_row ->> 'status', 'error');
    v_error := v_row ->> 'error';
    v_lessons := coalesce(v_row -> 'lessons', '[]'::jsonb);
    v_group := nullif(v_row ->> 'group_id', '')::uuid;
    v_db_year := null;
    v_db_name := null;
    v_starts := null;
    v_site_names := null;
    v_derived := null;
    if v_status in ('fetched', 'applied') then
      v_fetched := v_fetched + 1;
    else
      v_skipped := v_skipped + 1;
    end if;

    if v_status = 'applied'
       and v_group is not null
       and jsonb_array_length(v_lessons) > 0 then
      select coalesce(i.admission_year, gap.admission_year), g.name
        into v_db_year, v_db_name
      from public.groups g
      left join public.group_academic_identities i on i.group_id = g.id
      left join public.group_academic_profiles gap on gap.group_id = g.id
      where g.id = v_group;

      select coalesce(array_agg(distinct
        case
          when extract(month from (item ->> 'date')::date) >= 9
            then extract(year from (item ->> 'date')::date)::integer
          else extract(year from (item ->> 'date')::date)::integer - 1
        end
      ), '{}'::integer[])
        into v_starts
      from jsonb_array_elements(v_lessons) item
      where nullif(item ->> 'date', '') is not null;

      select coalesce(array_agg(distinct btrim(item ->> 'group_name')), '{}'::text[])
        into v_site_names
      from jsonb_array_elements(v_lessons) item
      where nullif(btrim(item ->> 'group_name'), '') is not null;

      if cardinality(v_starts) <> 1 then
        v_status := 'skipped';
        v_error := 'schedule_dates_span_multiple_years';
      elsif v_db_year is null then
        v_status := 'skipped';
        v_error := 'group_identity_missing';
      elsif cardinality(v_site_names) > 1 then
        v_status := 'skipped';
        v_error := 'schedule_group_name_conflict';
      else
        v_site_name := coalesce(v_site_names[1], coalesce(v_row ->> 'group_name', v_db_name));
        if private.group_recognition_name_key(v_site_name)
           is distinct from private.group_recognition_name_key(v_db_name) then
          v_status := 'skipped';
          v_error := 'schedule_group_name_mismatch';
        else
          v_parsed := private.parse_academic_group_name(v_site_name, 'group-name-v1');
          select y.admission_year, y.error
            into v_derived, v_year_error
          from private.academic_group_years_from_parsed(v_parsed, v_starts[1]) y;
          if v_year_error is not null then
            v_status := 'skipped';
            v_error := v_year_error;
          elsif v_derived is distinct from v_db_year then
            v_status := 'skipped';
            v_error := 'group_admission_year_conflict';
          end if;
        end if;
      end if;

      if v_status = 'applied' then
        select min((item ->> 'date')::date), max((item ->> 'date')::date)
          into v_min, v_max
        from jsonb_array_elements(v_lessons) item
        where nullif(item ->> 'date', '') is not null;
        if v_min is not null then
          delete from public.lessons
          where group_id = v_group and date between v_min and v_max;
          for v_lesson in select value from jsonb_array_elements(v_lessons)
          loop
            insert into public.lessons(
              group_id, week, day, date, pair_num, time_start, time_end,
              subject, room, teacher, raw_subject_name
            ) values (
              v_group,
              nullif(v_lesson ->> 'week', '')::integer,
              v_lesson ->> 'day',
              nullif(v_lesson ->> 'date', '')::date,
              nullif(v_lesson ->> 'pair_num', '')::integer,
              nullif(v_lesson ->> 'time_start', '')::time,
              nullif(v_lesson ->> 'time_end', '')::time,
              v_lesson ->> 'subject',
              v_lesson ->> 'room',
              v_lesson ->> 'teacher',
              v_lesson ->> 'subject'
            );
          end loop;
          v_subject_sync := v_subject_sync || jsonb_build_array(
            private.sync_schedule_subjects(v_group,v_min,v_max,false));
          v_applied := v_applied + 1;
        else
          v_status := 'error';
          v_error := 'schedule_dates_missing';
          v_skipped := v_skipped + 1;
          v_fetched := v_fetched - 1;
        end if;
      else
        v_skipped := v_skipped + 1;
        v_fetched := v_fetched - 1;
      end if;
    elsif v_status = 'applied' then
      v_status := 'skipped';
      v_skipped := v_skipped + 1;
      v_fetched := v_fetched - 1;
    end if;

    insert into public.rasp_schedule_run_groups(
      run_id, group_id, group_name, admission_year, status, error,
      academic_year_start, derived_admission_year, lesson_count, applied, lessons
    ) values (
      v_run_id,
      v_group,
      coalesce(v_row ->> 'group_name', ''),
      coalesce(v_db_year, nullif(v_row ->> 'admission_year', '')::integer),
      v_status,
      v_error,
      coalesce(v_starts[1], nullif(v_row ->> 'academic_year_start', '')::integer),
      coalesce(v_derived, nullif(v_row ->> 'derived_admission_year', '')::integer),
      jsonb_array_length(v_lessons),
      v_status = 'applied',
      v_lessons
    );
  end loop;

  update public.rasp_schedule_runs
  set finished_at = now(),
      group_count = v_count,
      fetched_count = v_fetched,
      applied_count = v_applied,
      skipped_count = v_skipped,
      summary = jsonb_build_object(
        'group_count', v_count,
        'fetched', v_fetched,
        'applied', v_applied,
        'skipped', v_skipped,
        'subject_sync', v_subject_sync
      )
  where id = v_run_id;

  if to_regprocedure('private.admin_write_audit(text,text,text,jsonb)') is not null then
    perform private.admin_write_audit(
      'rasp_schedule.run',
      'rasp_schedule_run',
      v_run_id::text,
      jsonb_build_object(
        'trigger', p_payload ->> 'trigger',
        'group_count', v_count,
        'applied', v_applied,
        'skipped', v_skipped
      )
    );
  end if;

  return public.admin_get_rasp_schedule_run(v_run_id);
end;
$function$
