-- Stage 14.1.4: expose vacancy_assets.role to mobile get_my_vacancies.
-- Additive dual-read: older clients ignore unknown JSON keys.
-- Does not enable content_visual_studio_v2_publish.

create or replace function public.get_my_vacancies()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_groups uuid[];
  v_eligible boolean;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.users u where u.id = v_uid and u.is_active) then
    return '[]'::jsonb;
  end if;

  v_groups := private.current_user_active_group_ids();
  v_eligible := coalesce(array_length(v_groups, 1), 0) > 0;
  if not v_eligible then
    return '[]'::jsonb;
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', v.id,
          'title', v.title,
          'company_name', v.company_name,
          'summary', v.summary,
          'description', v.description,
          'employment_type', v.employment_type,
          'work_format', v.work_format,
          'location', v.location,
          'salary_text', v.salary_text,
          'external_url', v.external_url,
          'origin', v.origin,
          'is_demo', (v.origin = 'demo'),
          'published_at', v.published_at,
          'expires_at', v.expires_at,
          'has_contacts', (v.contacts <> '{}'::jsonb),
          'assets', coalesce(
            (
              select jsonb_agg(
                jsonb_build_object(
                  'id', a.id,
                  'title', coalesce(nullif(btrim(a.title), ''), ''),
                  'mime_type', a.mime_type,
                  'role', coalesce(nullif(btrim(a.role), ''), 'attachment')
                )
                order by a.created_at, a.id
              )
              from public.vacancy_assets a
              where a.vacancy_id = v.id
                and a.working_draft_id is null
            ),
            '[]'::jsonb
          )
        )
        order by v.priority desc, v.published_at desc nulls last
      )
      from public.vacancies v
      where v.status = 'published'
        and not v.is_hidden
        and (v.starts_at is null or v.starts_at <= v_now)
        and (v.ends_at is null or v.ends_at > v_now)
        and (v.expires_at is null or v.expires_at > v_now)
        and (
          v.audience_mode = 'all'
          or (
            v.audience_mode in ('groups', 'groups_and_users')
            and exists (
              select 1
              from public.vacancy_audience_groups g
              where g.vacancy_id = v.id
                and g.group_id = any (v_groups)
            )
          )
          or (
            v.audience_mode in ('users', 'groups_and_users')
            and exists (
              select 1
              from public.vacancy_audience_users au
              where au.vacancy_id = v.id
                and au.user_id = v_uid
            )
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

revoke all on function public.get_my_vacancies() from public, anon;
grant execute on function public.get_my_vacancies() to authenticated, service_role;

comment on function public.get_my_vacancies() is
  'Published vacancies for the current student; assets include role (logo/cover/background/attachment).';
