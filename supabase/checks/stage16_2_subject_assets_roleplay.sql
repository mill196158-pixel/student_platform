-- Stage 16.2 behavioral roleplay (LOCAL ONLY, disposable).
-- Depends on:
--   20260729150600_stage16_2_subject_assets.sql
--   20260729150650_stage16_2_subject_assets_hardening.sql
--   20260729150660_stage16_2_subject_assets_p1_fixes.sql
--   20260729150670_stage16_2_subject_assets_p1_r2.sql
--
-- Covers: hero MIME mismatch, draft current delete, published current denial,
-- supersede chain, cleanup lease claim/complete, finalize without storage SKIP,
-- service_role register with null auth.uid() (nullable created_by).
-- register uses service_role (authenticated revoke per P1 #3).
-- Edge processCleanup auth (CLEANUP_DISPATCH_SECRET / service_role only) is
-- enforced in supabase/functions/subject-media/index.ts — not SQL.

begin;

do $$
declare
  v_admin uuid;
  v_subject uuid;
  v_intent jsonb;
  v_asset jsonb;
  v_asset2 jsonb;
  v_cat_ver integer;
  v_prof_ver integer;
  v_queue_id uuid;
  v_claim_token uuid;
  v_claimed record;
begin
  select id into v_admin from public.users where login = 'admin_roleplay' limit 1;
  if v_admin is null then
    raise notice 'stage16_2 roleplay SKIP: fixture users missing';
    return;
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  select (public.admin_upsert_subject_card(
    null, 0, 0,
    'Roleplay Subject 16.2 P1',
    'Full description',
    'IT', 'Exam', 'medium', 'Req', 'Outcomes',
    '[]'::jsonb,
    'draft',
    'Short', 'Expect', 'Prep', 'Materials', 'Pitfalls',
    current_date,
    '[]'::jsonb
  )->>'id')::uuid into v_subject;

  -- hero MIME mismatch (pdf for hero) must fail
  begin
    perform public.admin_create_subject_asset_upload_intent(
      v_subject, null, 'hero_image', 'application/pdf', null, 60
    );
    raise exception 'expected hero MIME rejection';
  exception when others then
    if sqlerrm not ilike '%mime%' and sqlerrm not ilike '%invalid%' then
      raise;
    end if;
  end;

  v_intent := public.admin_create_subject_asset_upload_intent(
    v_subject, null, 'hero_image', 'image/png', null, 60
  );

  -- Without storage.objects row, finalize must fail closed (not trust client size)
  begin
    perform public.admin_finalize_subject_asset_upload(
      (v_intent->>'intent_id')::uuid,
      'Hero',
      null,
      null
    );
    raise exception 'expected finalize without storage object to fail';
  exception when others then
    if sqlerrm ilike '%expected finalize%' then
      raise;
    end if;
    raise notice 'stage16_2 roleplay: finalize without storage SKIP (expected)';
  end;

  -- authenticated must NOT register directly (P1 #3)
  begin
    perform public.admin_register_subject_asset(
      v_subject, null,
      'subject/' || v_subject::text || '/hero-auth.png',
      'image/png', 1024, 'Hero', null, null, 'hero_image', null
    );
    raise exception 'expected authenticated register denial';
  exception when others then
    if sqlerrm not ilike '%service_role%' and sqlerrm not ilike '%42501%' then
      raise;
    end if;
  end;

  -- service_role register with NULL auth.uid (no zero-UUID FK break)
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '', true);

  v_asset := public.admin_register_subject_asset(
    v_subject, null,
    'subject/' || v_subject::text || '/hero-draft.png',
    'image/png', 1024, 'Hero draft', null, null, 'hero_image', null
  );

  if exists (
    select 1 from public.subject_assets
    where id = (v_asset->>'id')::uuid
      and created_by = '00000000-0000-0000-0000-000000000000'::uuid
  ) then
    raise exception 'register must not use zero-UUID created_by';
  end if;

  if not exists (
    select 1 from public.admin_audit_log
    where action = 'subject_asset.register'
      and entity_type = 'subject_catalog'
      and entity_id = v_subject::text
      and (metadata->>'asset_id') = (v_asset->>'id')
  ) then
    raise exception 'register must write subject_asset.register audit';
  end if;

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  perform public.admin_delete_subject_asset((v_asset->>'id')::uuid);

  -- Supersede chain via service_role register
  perform set_config('request.jwt.claim.role', 'service_role', true);

  v_asset := public.admin_register_subject_asset(
    v_subject, null,
    'subject/' || v_subject::text || '/hero-v1.png',
    'image/png', 1024, 'Hero v1', null, null, 'hero_image', null
  );

  v_asset2 := public.admin_register_subject_asset(
    v_subject, null,
    'subject/' || v_subject::text || '/hero-v2.png',
    'image/png', 2048, 'Hero v2', null,
    (v_asset->>'id')::uuid,
    'hero_image',
    (v_asset->>'logical_asset_id')::uuid
  );

  if (v_asset2->>'version_number')::integer <= (v_asset->>'version_number')::integer then
    raise exception 'supersede did not bump version_number';
  end if;

  -- Publish then deny delete of current hero
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  select sc.row_version, p.row_version into v_cat_ver, v_prof_ver
  from public.subject_catalog sc
  join public.subject_student_profiles p on p.subject_id = sc.id
  where sc.id = v_subject;

  perform public.admin_upsert_subject_card(
    v_subject, v_cat_ver, v_prof_ver,
    'Roleplay Subject 16.2 P1', 'Full description',
    'IT', 'Exam', 'medium', 'Req', 'Outcomes',
    '[]'::jsonb, 'published',
    'Short', 'Expect', 'Prep', 'Materials', 'Pitfalls',
    current_date, '[]'::jsonb
  );

  begin
    perform public.admin_delete_subject_asset((v_asset2->>'id')::uuid);
    raise exception 'expected published current delete denial';
  exception when others then
    if sqlerrm not ilike '%unpublish%'
       and sqlerrm not ilike '%published%'
       and sqlerrm not ilike '%supersede%' then
      raise;
    end if;
  end;

  -- Cleanup lease: enqueue historical row path, claim + complete with token
  perform set_config('request.jwt.claim.role', 'service_role', true);

  insert into public.subject_media_cleanup_queue (
    storage_bucket, storage_path, source_subject_catalog_id, source_title
  ) values (
    'subject-media',
    'subject/' || v_subject::text || '/lease-test.bin',
    v_subject,
    'lease test'
  )
  returning id into v_queue_id;

  select * into v_claimed
  from public.claim_subject_media_cleanup_batch(1, 120)
  limit 1;

  if v_claimed.id is null or v_claimed.claim_token is null then
    raise exception 'cleanup claim returned no lease';
  end if;

  perform public.complete_subject_media_cleanup(
    v_claimed.id,
    v_claimed.claim_token
  );

  -- authorize_subject_asset_download must not expose storage_path
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'authorize_subject_asset_download'
      and p.prosrc ilike '%storage_path%'
  ) then
    raise exception 'authorize_subject_asset_download leaks storage_path';
  end if;

  raise notice 'stage16_2_subject_assets_roleplay OK';
end $$;

rollback;
