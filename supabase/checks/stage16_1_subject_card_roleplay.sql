-- Stage 16.1 behavioral roleplay (LOCAL ONLY, disposable).
-- Entire run is transactional and rolled back. Missing fixtures → NOTICE skip.
-- Any other failure RAISES (does not swallow into success).

begin;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_other uuid;
  v_group uuid;
  v_other_group uuid;
  v_subject uuid;
  v_offering uuid;
  v_other_offering uuid;
  v_teacher uuid;
  v_cs uuid;
  v_year uuid;
  v_term uuid;
  v_cat_ver integer;
  v_prof_ver integer;
  v_teach_ver integer;
  v_override_ver integer;
  v_card jsonb;
  v_versions jsonb;
begin
  select id into v_admin from public.users where login = 'admin_roleplay' limit 1;
  select id into v_student from public.users where login = 'student_roleplay' limit 1;
  select id into v_other from public.users where login = 'student_other_roleplay' limit 1;
  if v_admin is null or v_student is null then
    raise notice 'stage16_1 roleplay SKIP: fixture users missing';
    return;
  end if;

  select group_id into v_group
  from public.student_enrollments
  where user_id = v_student and status = 'active' and ended_at is null
  limit 1;
  if v_group is null then
    raise notice 'stage16_1 roleplay SKIP: student enrollment missing';
    return;
  end if;

  select id into v_year from public.academic_years order by created_at desc nulls last limit 1;
  select id into v_term from public.academic_terms order by created_at desc nulls last limit 1;
  if v_year is null or v_term is null then
    raise notice 'stage16_1 roleplay SKIP: academic year/term missing';
    return;
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  select (public.admin_upsert_subject_card(
    null, 0, 0,
    'Roleplay Subject 16.1',
    'Full description',
    'IT', 'Exam', 'medium', 'Req', 'Outcomes',
    '[{"title":"Docs","url":"https://example.com"}]'::jsonb,
    'published',
    'Short', 'Expect', 'Prep', 'Materials', 'Pitfalls',
    current_date,
    '["description","short_description"]'::jsonb
  )->>'id')::uuid into v_subject;

  select sc.row_version, p.row_version
  into v_cat_ver, v_prof_ver
  from public.subject_catalog sc
  join public.subject_student_profiles p on p.subject_id = sc.id
  where sc.id = v_subject;

  begin
    perform public.admin_upsert_subject_card(
      v_subject, v_cat_ver, v_prof_ver,
      'Roleplay Subject 16.1', null, null, null, null, null, null,
      '[]'::jsonb, 'published', null, null, null, null, null, null,
      '["nope"]'::jsonb
    );
    raise exception 'expected unknown_section_order_key';
  exception
    when others then
      if sqlerrm not ilike '%unknown_section_order%'
         and sqlerrm not ilike '%invalid_section%' then
        raise;
      end if;
  end;

  begin
    perform public.admin_upsert_subject_card(
      v_subject, v_cat_ver - 1, v_prof_ver,
      'Roleplay Subject 16.1', null, null, null, null, null, null,
      '[]'::jsonb, 'published', null, null, null, null, null, null,
      '[]'::jsonb
    );
    raise exception 'expected row_version_conflict';
  exception
    when others then
      if sqlerrm not ilike '%row_version_conflict%' then
        raise;
      end if;
  end;

  insert into public.curriculum_subjects(
    subject_id, raw_subject_name, display_name, hours_total, credits
  ) values (
    v_subject, 'CS Roleplay', 'CS Roleplay', 108, 3
  )
  returning id into v_cs;

  insert into public.subject_offerings(
    subject_id, group_id, curriculum_subject_id,
    academic_year_id, academic_term_id, semester_number, display_name, status
  ) values (
    v_subject, v_group, v_cs, v_year, v_term, 1, 'Offering A', 'active'
  )
  returning id into v_offering;

  select id into v_teacher from public.teachers limit 1;
  if v_teacher is null then
    insert into public.teachers(full_name, normalized_name)
    values ('Teacher Roleplay', 'teacher roleplay')
    returning id into v_teacher;
  end if;

  select teachers_row_version into v_teach_ver
  from public.subject_offerings where id = v_offering;

  begin
    perform public.admin_set_offering_teachers(
      v_offering, v_teach_ver, array[gen_random_uuid()]
    );
    raise exception 'expected unknown_teacher_id';
  exception
    when others then
      if sqlerrm not ilike '%unknown_teacher%' then
        raise;
      end if;
  end;

  perform public.admin_set_offering_teachers(
    v_offering, v_teach_ver, array[v_teacher]
  );

  select (public.admin_upsert_offering_student_profile(
    v_offering, 0,
    'Local desc override',
    'Teacher note',
    'Assessment',
    'Workload',
    'Semester tips override',
    'published'
  )->>'row_version')::integer into v_override_ver;

  v_versions := public.admin_list_offering_profile_versions(v_offering);
  if jsonb_array_length(v_versions) < 1 then
    raise exception 'expected offering profile versions';
  end if;

  perform public.admin_restore_offering_student_profile(
    v_offering,
    (v_versions->0->>'version_number')::integer,
    v_override_ver
  );

  perform set_config('request.jwt.claim.sub', v_student::text, true);
  v_card := public.get_subject_card(v_offering);
  if coalesce(v_card->>'description', '') <> 'Local desc override' then
    raise exception 'merge local_description failed: %', v_card->>'description';
  end if;
  if coalesce(v_card->>'how_to_pass', '') <> 'Semester tips override' then
    raise exception 'merge semester_tips failed';
  end if;
  if (v_card->>'hours_credits_available')::boolean is not true then
    raise exception 'hours_credits_available expected true';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  update public.subject_catalog set status = 'draft' where id = v_subject;
  perform set_config('request.jwt.claim.sub', v_student::text, true);
  begin
    perform public.get_subject_card(v_offering);
    raise exception 'expected unpublished denial';
  exception
    when others then
      if sqlerrm not ilike '%not_found%' and sqlstate <> 'P0002' then
        raise;
      end if;
  end;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  update public.subject_catalog set status = 'published' where id = v_subject;

  if v_other is not null then
    select group_id into v_other_group
    from public.student_enrollments
    where user_id = v_other and status = 'active' and ended_at is null
      and group_id is distinct from v_group
    limit 1;
    if v_other_group is not null then
      insert into public.subject_offerings(
        subject_id, group_id, curriculum_subject_id,
        academic_year_id, academic_term_id, semester_number, display_name, status
      ) values (
        v_subject, v_other_group, v_cs, v_year, v_term, 1, 'Offering B', 'active'
      )
      returning id into v_other_offering;
      perform set_config('request.jwt.claim.sub', v_student::text, true);
      begin
        perform public.get_subject_card(v_other_offering);
        raise exception 'expected cross-group forbidden';
      exception
        when others then
          if sqlstate <> '42501' and sqlerrm not ilike '%forbidden%' then
            raise;
          end if;
      end;
    end if;
  end if;

  raise notice 'stage16_1_subject_card_roleplay OK';
end $$;

rollback;
