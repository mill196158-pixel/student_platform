-- Restore the previous importer; do not delete generated educational data.
CREATE OR REPLACE FUNCTION public.admin_save_rasp_schedule_run(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_run_id uuid;
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
          when extract(month from (item ->> 'date')::date) >= 8
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
        'skipped', v_skipped
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

drop function if exists public.admin_bind_schedule_subject(uuid,text,uuid);
drop function if exists public.admin_list_unlinked_schedule_subjects();
drop function if exists public.admin_sync_schedule_subjects(uuid,date,date,boolean);
drop function if exists private.sync_schedule_subjects(uuid,date,date,boolean,text);
