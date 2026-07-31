-- Stage 2.1 dev/test seed: schedule -> subject_offering -> team/chat link.
-- This is intentionally NOT a production migration.
-- It is idempotent and marked with:
--   subject_catalog.description = 'stage2_1_test_schedule_subject_link'
--   subject_aliases.source      = 'stage2_1_test_schedule_subject_link'
--   curriculum_subjects.subject_index starts with 'STAGE2.1-TEST'
--   teams.description contains 'stage2_1_test_schedule_subject_link'
--   lessons.raw_subject_name and normalized_subject_name are filled.

begin;

do $$
declare
  v_marker constant text := 'stage2_1_test_schedule_subject_link';
  v_year_id uuid;
  v_term_id uuid;
  v_semester int;
  v_subject_id uuid;
  v_curriculum_subject_id uuid;
  v_subject_offering_id uuid;
  v_team_id uuid;
  v_chat_id uuid;
  r record;
  a record;
  l record;
begin
  if to_regclass('public.lessons') is null then
    raise exception 'public.lessons table not found';
  end if;

  for r in
    select *
    from (
      values
        ('1-См(ВВ)-2'::text, 'Тест 1'::text,     'Тестовый преподаватель 1'::text),
        ('1-См(ВВ)-2'::text, 'Тест 2'::text,     'Тестовый преподаватель 2'::text),
        ('2-См(ВВ)-2'::text, 'Проверка 1'::text, 'Тестовый преподаватель 3'::text),
        ('2-См(ВВ)-2'::text, 'Проверка 2'::text, 'Тестовый преподаватель 4'::text)
    ) as seed(group_name, subject_name, teacher_name)
  loop
    select
      gts.academic_year_id,
      gts.academic_term_id,
      gts.semester_number
    into v_year_id, v_term_id, v_semester
    from public.groups g
    join public.group_term_semesters gts on gts.group_id = g.id
    join public.academic_terms at on at.id = gts.academic_term_id
    where g.name = r.group_name
      and at.is_current = true
    order by gts.semester_number desc
    limit 1;

    if v_year_id is null then
      select
        gts.academic_year_id,
        gts.academic_term_id,
        gts.semester_number
      into v_year_id, v_term_id, v_semester
      from public.groups g
      join public.group_term_semesters gts on gts.group_id = g.id
      where g.name = r.group_name
        and gts.semester_number = 4
      limit 1;
    end if;

    if v_year_id is null or v_term_id is null or v_semester is null then
      raise exception 'No current/semester 4 academic term found for group %', r.group_name;
    end if;

    insert into public.subject_catalog (canonical_name, normalized_name, description)
    values (r.subject_name, public.f_norm_title(r.subject_name), v_marker)
    on conflict (normalized_name) do update
      set canonical_name = excluded.canonical_name,
          description = excluded.description,
          updated_at = now();

    select id
    into v_subject_id
    from public.subject_catalog
    where normalized_name = public.f_norm_title(r.subject_name);

    if r.subject_name = 'Тест 1' then
      for a in
        select *
        from (
          values
            ('Тест 1'::text),
            ('Тест 1 (сем.)'::text),
            ('Тест 1 семинар'::text),
            ('Тест 1, практика'::text),
            ('Тест 1 Teams TEST-1'::text),
            ('Тест 1, практика Teams TEST-1'::text)
        ) as aliases(alias)
      loop
        insert into public.subject_aliases (subject_id, alias, normalized_alias, source)
        values (v_subject_id, a.alias, public.f_norm_title(a.alias), v_marker)
        on conflict (normalized_alias) do update
          set subject_id = excluded.subject_id,
              alias = excluded.alias,
              source = excluded.source;
      end loop;
    elsif r.subject_name = 'Тест 2' then
      for a in
        select *
        from (
          values
            ('Тест 2'::text),
            ('Тест 2 (л.)'::text),
            ('Тест 2 лекция'::text),
            ('Тест 2 (лаб.)'::text),
            ('Тест 2 лабораторная'::text)
        ) as aliases(alias)
      loop
        insert into public.subject_aliases (subject_id, alias, normalized_alias, source)
        values (v_subject_id, a.alias, public.f_norm_title(a.alias), v_marker)
        on conflict (normalized_alias) do update
          set subject_id = excluded.subject_id,
              alias = excluded.alias,
              source = excluded.source;
      end loop;
    elsif r.subject_name = 'Проверка 1' then
      for a in
        select *
        from (
          values
            ('Проверка 1'::text),
            ('Проверка 1 (сем.)'::text),
            ('Проверка 1 семинар'::text),
            ('Проверка 1, практика'::text),
            ('Проверка 1 Teams TEST-A'::text),
            ('Проверка 1, практика Teams TEST-A'::text)
        ) as aliases(alias)
      loop
        insert into public.subject_aliases (subject_id, alias, normalized_alias, source)
        values (v_subject_id, a.alias, public.f_norm_title(a.alias), v_marker)
        on conflict (normalized_alias) do update
          set subject_id = excluded.subject_id,
              alias = excluded.alias,
              source = excluded.source;
      end loop;
    elsif r.subject_name = 'Проверка 2' then
      for a in
        select *
        from (
          values
            ('Проверка 2'::text),
            ('Проверка 2 (л.)'::text),
            ('Проверка 2 лекция'::text),
            ('Проверка 2 (лаб.)'::text),
            ('Проверка 2 лабораторная'::text)
        ) as aliases(alias)
      loop
        insert into public.subject_aliases (subject_id, alias, normalized_alias, source)
        values (v_subject_id, a.alias, public.f_norm_title(a.alias), v_marker)
        on conflict (normalized_alias) do update
          set subject_id = excluded.subject_id,
              alias = excluded.alias,
              source = excluded.source;
      end loop;
    end if;

    select id
    into v_curriculum_subject_id
    from public.curriculum_subjects
    where subject_id = v_subject_id
      and raw_subject_name = r.subject_name
      and display_name = r.subject_name
      and semester_number = v_semester
      and subject_index = 'STAGE2.1-TEST-' || public.f_norm_title(r.subject_name)
    limit 1;

    if v_curriculum_subject_id is null then
      insert into public.curriculum_subjects (
        subject_id,
        raw_subject_name,
        display_name,
        semester_number,
        hours_total,
        credits,
        subject_index,
        block_name,
        control_form,
        department,
        subject_type,
        subject_kind,
        is_elective
      )
      values (
        v_subject_id,
        r.subject_name,
        r.subject_name,
        v_semester,
        0,
        0,
        'STAGE2.1-TEST-' || public.f_norm_title(r.subject_name),
        'Stage 2.1 test seed',
        'test',
        'dev',
        'dev_test',
        'dev_test',
        false
      )
      returning id into v_curriculum_subject_id;
    end if;

    select so.id
    into v_subject_offering_id
    from public.subject_offerings so
    join public.groups g on g.id = so.group_id
    where g.name = r.group_name
      and so.subject_id = v_subject_id
      and so.curriculum_subject_id = v_curriculum_subject_id
      and so.academic_year_id = v_year_id
      and so.academic_term_id = v_term_id
      and so.semester_number = v_semester
    limit 1;

    if v_subject_offering_id is null then
      insert into public.subject_offerings (
        subject_id,
        curriculum_subject_id,
        group_id,
        academic_year_id,
        academic_term_id,
        semester_number,
        display_name,
        status
      )
      select
        v_subject_id,
        v_curriculum_subject_id,
        g.id,
        v_year_id,
        v_term_id,
        v_semester,
        r.subject_name,
        'active'
      from public.groups g
      where g.name = r.group_name
      returning id into v_subject_offering_id;
    end if;

    for l in
      select *
      from (
        values
          ('1-См(ВВ)-2'::text, 'Тест 1'::text,     date '2026-06-19', 'ПТ'::text, 1, time '09:00', time '10:30', 'Тест 1 (сем.)'::text,                         'Тестовая аудитория 101'::text, 'Тестовый преподаватель 1'::text),
          ('1-См(ВВ)-2'::text, 'Тест 2'::text,     date '2026-06-19', 'ПТ'::text, 2, time '10:40', time '12:10', 'Тест 2 (л.)'::text,                           'Тестовая аудитория 102'::text, 'Тестовый преподаватель 2'::text),
          ('1-См(ВВ)-2'::text, 'Тест 1'::text,     date '2026-06-21', 'ВС'::text, 1, time '09:00', time '10:30', 'Тест 1, практика Teams TEST-1'::text,          'Teams TEST-1'::text,           'Тестовый преподаватель 1'::text),
          ('1-См(ВВ)-2'::text, 'Тест 2'::text,     date '2026-06-21', 'ВС'::text, 2, time '10:40', time '12:10', 'Тест 2 (лаб.)'::text,                         'Тестовая лаборатория 1'::text, 'Тестовый преподаватель 2'::text),
          ('2-См(ВВ)-2'::text, 'Проверка 1'::text, date '2026-06-19', 'ПТ'::text, 1, time '09:00', time '10:30', 'Проверка 1 (сем.)'::text,                     'Тестовая аудитория 201'::text, 'Тестовый преподаватель 3'::text),
          ('2-См(ВВ)-2'::text, 'Проверка 2'::text, date '2026-06-19', 'ПТ'::text, 2, time '10:40', time '12:10', 'Проверка 2 (л.)'::text,                       'Тестовая аудитория 202'::text, 'Тестовый преподаватель 4'::text),
          ('2-См(ВВ)-2'::text, 'Проверка 1'::text, date '2026-06-21', 'ВС'::text, 1, time '09:00', time '10:30', 'Проверка 1, практика Teams TEST-A'::text,      'Teams TEST-A'::text,           'Тестовый преподаватель 3'::text),
          ('2-См(ВВ)-2'::text, 'Проверка 2'::text, date '2026-06-21', 'ВС'::text, 2, time '10:40', time '12:10', 'Проверка 2 (лаб.)'::text,                     'Тестовая лаборатория 2'::text, 'Тестовый преподаватель 4'::text)
      ) as lessons(group_name, subject_name, lesson_date, day_code, pair_num, time_start, time_end, raw_title, room, teacher)
      where lessons.group_name = r.group_name
        and lessons.subject_name = r.subject_name
    loop
      insert into public.lessons (
        group_id,
        week,
        day,
        date,
        pair_num,
        time_start,
        time_end,
        subject,
        room,
        teacher,
        subject_id,
        subject_offering_id,
        academic_year_id,
        academic_term_id,
        semester_number,
        raw_subject_name,
        normalized_subject_name,
        alias_match_status
      )
      select
        g.id,
        1,
        l.day_code,
        l.lesson_date,
        l.pair_num,
        l.time_start,
        l.time_end,
        l.raw_title,
        l.room,
        l.teacher,
        v_subject_id,
        v_subject_offering_id,
        v_year_id,
        v_term_id,
        v_semester,
        l.raw_title,
        public.f_norm_title(l.raw_title),
        'matched'
      from public.groups g
      where g.name = l.group_name
        and not exists (
          select 1
          from public.lessons existing
          where existing.group_id = g.id
            and existing.date = l.lesson_date
            and existing.pair_num = l.pair_num
            and existing.time_start = l.time_start
            and existing.time_end = l.time_end
            and existing.subject = l.raw_title
        );
    end loop;

    select id
    into v_team_id
    from public.teams
    where subject_offering_id = v_subject_offering_id
    limit 1;

    if v_team_id is null then
      insert into public.teams (
        name,
        description,
        teacher,
        icon,
        group_name,
        group_id,
        subject_id,
        subject_offering_id,
        academic_year_id,
        academic_term_id,
        semester_number
      )
      select
        r.subject_name,
        'Stage 2.1 test team seed: ' || v_marker,
        r.teacher_name,
        'school',
        g.name,
        g.id,
        v_subject_id,
        v_subject_offering_id,
        v_year_id,
        v_term_id,
        v_semester
      from public.groups g
      where g.name = r.group_name
      returning id into v_team_id;
    end if;

    select id
    into v_chat_id
    from public.chats
    where team_id = v_team_id
      and type = 'team_main'
    limit 1;

    if v_chat_id is null then
      insert into public.chats (team_id, type, subject_offering_id)
      values (v_team_id, 'team_main', v_subject_offering_id)
      on conflict do nothing;
    end if;

    update public.chats
    set subject_offering_id = v_subject_offering_id
    where team_id = v_team_id
      and type = 'team_main'
      and subject_offering_id is null;

    insert into public.team_members (team_id, user_id, role)
    select v_team_id, se.user_id, 'member'
    from public.groups g
    join public.student_enrollments se
      on se.group_id = g.id
     and se.status = 'active'
     and se.ended_at is null
    where g.name = r.group_name
    on conflict do nothing;

    select id
    into v_chat_id
    from public.chats
    where team_id = v_team_id
      and type = 'team_main'
    limit 1;

    if v_chat_id is not null then
      insert into public.chat_members (chat_id, user_id, role_in_chat)
      select v_chat_id, se.user_id, 'member'
      from public.groups g
      join public.student_enrollments se
        on se.group_id = g.id
       and se.status = 'active'
       and se.ended_at is null
      where g.name = r.group_name
      on conflict do nothing;
    end if;
  end loop;
end $$;

commit;

with test_subjects as (
  select id, canonical_name
  from public.subject_catalog
  where description = 'stage2_1_test_schedule_subject_link'
    and canonical_name in ('Тест 1','Тест 2','Проверка 1','Проверка 2')
),
test_offerings as (
  select so.id, so.subject_id, so.group_id, so.display_name
  from public.subject_offerings so
  join test_subjects ts on ts.id = so.subject_id
),
test_teams as (
  select t.id, t.subject_offering_id
  from public.teams t
  join test_offerings so on so.id = t.subject_offering_id
),
test_chats as (
  select ch.id, ch.team_id
  from public.chats ch
  join test_teams t on t.id = ch.team_id
  where ch.type = 'team_main'
)
select 'subject_catalog' as object_type, count(*)::bigint as rows_count from test_subjects
union all select 'subject_aliases', count(*)::bigint from public.subject_aliases sa join test_subjects ts on ts.id = sa.subject_id
union all select 'curriculum_subjects', count(*)::bigint from public.curriculum_subjects cs join test_subjects ts on ts.id = cs.subject_id
union all select 'subject_offerings', count(*)::bigint from test_offerings
union all select 'lessons', count(*)::bigint from public.lessons l where l.subject_id in (select id from test_subjects) and l.date in ('2026-06-19','2026-06-21')
union all select 'teams', count(*)::bigint from test_teams
union all select 'chats', count(*)::bigint from test_chats
union all select 'team_members', count(*)::bigint from public.team_members tm join test_teams t on t.id = tm.team_id
union all select 'chat_members', count(*)::bigint from public.chat_members cm join test_chats ch on ch.id = cm.chat_id;
