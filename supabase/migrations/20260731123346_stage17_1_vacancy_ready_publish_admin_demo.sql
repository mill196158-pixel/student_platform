-- Stage 17.1: atomic ready-publish for Admin/Demo authored vacancy drafts.
-- User submissions and any row with submitted_by remain fail-closed
-- (must go through the normal moderation queue).

create or replace function public.admin_ready_publish_vacancy(
  p_id uuid,
  p_expected_row_version integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
  v_row public.vacancies;
  v_preview jsonb;
  v_count integer;
  v_from text;
begin
  -- Both gates required: moderation steps + final publish.
  perform private.require_any_admin_permission(
    array['moderation.action', 'moderation.write']
  );
  v_uid := private.require_admin_permission('content.publish');

  v_row := private.vacancy_lock(p_id, p_expected_row_version);
  v_from := v_row.status;

  if v_from <> 'draft' then
    raise exception 'ready_publish_draft_only' using errcode = 'P0001';
  end if;
  if v_row.origin not in ('admin', 'demo') then
    raise exception 'ready_publish_origin_forbidden' using errcode = '42501';
  end if;
  if v_row.submitted_by is not null then
    raise exception 'ready_publish_has_submitter' using errcode = '42501';
  end if;

  perform private.vacancy_assert_contacts(v_row.contacts);
  perform private.vacancy_assert_audience_consistent(p_id);

  if v_row.expires_at is not null and v_row.expires_at <= now() then
    raise exception 'already_expired' using errcode = 'P0001';
  end if;

  v_preview := private.vacancy_preview_audience_count(p_id);
  v_count := coalesce((v_preview ->> 'recipient_count')::integer, 0);
  if v_row.audience_mode <> 'all' and v_count = 0 then
    raise exception 'empty_audience' using errcode = 'P0001';
  end if;

  -- 1) draft → in_moderation
  perform private.vacancy_assert_transition(v_row.status, 'in_moderation');
  update public.vacancies v set
    status = 'in_moderation',
    moderated_by = v_uid,
    moderated_at = now(),
    rejection_reason = null,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;
  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(
    p_id, 'take_in_moderation', 'draft', 'in_moderation', 'ready_publish'
  );

  -- 2) in_moderation → approved
  perform private.vacancy_assert_transition(v_row.status, 'approved');
  update public.vacancies v set
    status = 'approved',
    moderated_by = v_uid,
    moderated_at = now(),
    rejection_reason = null,
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;
  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(
    p_id, 'approve', 'in_moderation', 'approved', 'ready_publish'
  );

  -- 3) approved → published
  perform private.vacancy_assert_transition(v_row.status, 'published');
  update public.vacancies v set
    status = 'published',
    published_by = v_uid,
    published_at = coalesce(v.published_at, now()),
    version_number = v.version_number + 1,
    row_version = v.row_version + 1,
    updated_by = v_uid,
    updated_at = now()
  where v.id = p_id
  returning * into v_row;
  perform private.vacancy_snapshot_version(p_id);
  perform private.vacancy_record_action(
    p_id, 'publish', 'approved', 'published', 'ready_publish'
  );

  return private.vacancy_to_admin_json(p_id);
end;
$$;

comment on function public.admin_ready_publish_vacancy(uuid, integer) is
  'Stage 17.1: atomic draft→in_moderation→approved→published for admin/demo '
  'vacancies with submitted_by IS NULL. Requires moderation.* + content.publish. '
  'Fail-closed for user_submission and any submitted row.';

revoke all on function public.admin_ready_publish_vacancy(uuid, integer)
  from public, anon;
grant execute on function public.admin_ready_publish_vacancy(uuid, integer)
  to authenticated, service_role;
