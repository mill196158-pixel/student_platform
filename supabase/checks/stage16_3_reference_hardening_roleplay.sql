-- Stage 16.3 hardening + content-media behavioral roleplay (LOCAL ONLY, disposable).

begin;

do $$
declare
  v_admin uuid;
  v_student uuid;
  v_cat jsonb;
  v_cat_id uuid;
  v_cat2 jsonb;
  v_article jsonb;
  v_article_id uuid;
  v_ver integer;
  v_ver_before integer;
  v_bundle jsonb;
  v_corr jsonb;
  v_ver_num integer;
  v_intent jsonb;
  v_path text;
  v_asset jsonb;
  v_asset_id uuid;
  v_orphan uuid;
  v_auth jsonb;
  v_claim public.content_media_cleanup_queue;
  v_claim_count integer;
  v_processed_id uuid;
begin
  select id into v_admin from public.users where login = 'admin_roleplay' limit 1;
  select id into v_student from public.users where login = 'student_roleplay' limit 1;
  if v_admin is null or v_student is null then
    raise notice 'stage16_3 hardening roleplay SKIP: fixture users missing';
    return;
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  -- Create draft category then publish (publish permission required for status change).
  v_cat := public.admin_upsert_reference_category(
    null, 0,
    jsonb_build_object(
      'key', 'roleplay_cat',
      'title', 'Roleplay Cat',
      'icon_key', 'map',
      'status', 'draft',
      'sort_order', 1
    )
  );
  v_cat_id := (v_cat->>'id')::uuid;
  v_cat := public.admin_upsert_reference_category(
    v_cat_id,
    (v_cat->>'row_version')::integer,
    jsonb_build_object(
      'title', 'Roleplay Cat',
      'icon_key', 'map',
      'status', 'published',
      'sort_order', 1,
      'key', 'mutated_key_should_be_ignored'
    )
  );
  if (v_cat->>'key') is distinct from 'roleplay_cat' then
    raise exception 'category key must be immutable after create';
  end if;
  if (v_cat->>'status') is distinct from 'published' then
    raise exception 'category publish failed';
  end if;

  v_article := public.admin_upsert_reference_article(
    null, 0,
    jsonb_build_object(
      'title', 'Roleplay Article',
      'origin', 'admin',
      'reference_category_id', v_cat_id,
      'schema_version', 2,
      'sort_order', 0,
      'payload', jsonb_build_object(
        'icon_key', 'info',
        'short_text', 'Short',
        'blocks', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', 'Hello reference')
        )
      )
    )
  );
  v_article_id := (v_article->>'id')::uuid;
  v_ver := (v_article->>'row_version')::integer;
  v_ver_num := (v_article->>'version_number')::integer;

  -- Category-only update must bump row_version + participate in versioning.
  v_ver_before := v_ver;
  v_article := public.admin_upsert_reference_article(
    v_article_id,
    v_ver,
    jsonb_build_object('reference_category_id', v_cat_id)
  );
  v_ver := (v_article->>'row_version')::integer;
  if v_ver <= v_ver_before then
    raise exception 'category-only update must bump row_version';
  end if;

  -- Media intent: no storage_path leak.
  v_intent := public.admin_create_content_asset_upload_intent(
    v_article_id, 'image/png', 900
  );
  if v_intent ? 'storage_path' then
    raise exception 'upload intent leaked storage_path to client';
  end if;
  if nullif(v_intent->>'intent_id', '') is null then
    raise exception 'upload intent missing intent_id';
  end if;

  -- Finalize without storage object fails closed.
  begin
    perform public.admin_finalize_content_asset_upload(
      (v_intent->>'intent_id')::uuid, 'map'
    );
    raise exception 'expected storage_object_missing on finalize';
  exception when others then
    if sqlerrm not ilike '%storage_object_missing%'
       and sqlerrm not ilike '%storage%' then
      raise;
    end if;
  end;

  -- Seed disposable Storage fixture via service_role path resolver.
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '', true);
  v_path := (
    public.service_content_upload_intent_storage_path(
      (v_intent->>'intent_id')::uuid
    )->>'storage_path'
  );
  if v_path is null or length(v_path) = 0 then
    raise exception 'service path resolver returned empty path';
  end if;

  insert into storage.objects (bucket_id, name, owner, metadata)
  values (
    'content-media',
    v_path,
    v_admin,
    jsonb_build_object('mimetype', 'image/png', 'size', '1024')
  );

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  v_asset := public.admin_finalize_content_asset_upload(
    (v_intent->>'intent_id')::uuid, 'Campus map'
  );
  v_asset_id := (v_asset->>'id')::uuid;
  if v_asset_id is null then
    raise exception 'finalize did not return asset id';
  end if;

  -- Attach asset in payload, then publish.
  v_article := public.admin_upsert_reference_article(
    v_article_id,
    v_ver,
    jsonb_build_object(
      'payload', jsonb_build_object(
        'icon_key', 'info',
        'short_text', 'Short',
        'blocks', jsonb_build_array(
          jsonb_build_object('type', 'text', 'text', 'Hello reference'),
          jsonb_build_object(
            'type', 'image',
            'asset_id', v_asset_id::text,
            'caption', 'Map'
          )
        )
      )
    )
  );
  v_ver := (v_article->>'row_version')::integer;

  v_article := public.admin_publish_content(v_article_id, v_ver);
  v_ver := (v_article->>'row_version')::integer;

  -- Student may download referenced asset.
  perform set_config('request.jwt.claim.sub', v_student::text, true);
  v_auth := public.authorize_content_asset_download(v_asset_id);
  if coalesce((v_auth->>'authorized')::boolean, false) is not true then
    raise exception 'student download of referenced asset denied';
  end if;

  -- Orphan asset (same item, not in payload) must be denied for students.
  insert into public.content_assets (
    content_item_id, storage_bucket, storage_path, mime_type, byte_size, created_by
  ) values (
    v_article_id,
    'content-media',
    'content/' || v_article_id::text || '/orphan-' || gen_random_uuid()::text || '.png',
    'image/png',
    512,
    v_admin
  )
  returning id into v_orphan;

  begin
    perform public.authorize_content_asset_download(v_orphan);
    raise exception 'expected orphan asset download denial';
  exception when others then
    if sqlerrm not ilike '%forbidden%' and sqlerrm not ilike '%42501%' then
      raise;
    end if;
  end;

  -- Cleanup claim/complete/fail + processed-row exclusion (service_role).
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claim.sub', '', true);

  insert into public.content_media_cleanup_queue (
    storage_bucket, storage_path, source_content_item_id, source_title, processed_at
  ) values (
    'content-media',
    'content/processed-skip.png',
    v_article_id,
    'processed',
    now()
  )
  returning id into v_processed_id;

  insert into public.content_media_cleanup_queue (
    storage_bucket, storage_path, source_content_item_id, source_title
  ) values (
    'content-media',
    'content/pending-cleanup.png',
    v_article_id,
    'pending'
  );

  v_claim_count := 0;
  for v_claim in
    select * from public.claim_content_media_cleanup_batch(25, 600)
  loop
    if v_claim.id = v_processed_id then
      raise exception 'processed cleanup row must not be claimed';
    end if;
    if v_claim.storage_path = 'content/pending-cleanup.png' then
      v_claim_count := 1;
      perform public.fail_content_media_cleanup(
        v_claim.id, v_claim.claim_token, 'roleplay_fail'
      );
      if not exists (
        select 1 from public.content_media_cleanup_queue q
        where q.id = v_claim.id
          and q.claim_token is null
          and q.last_error = 'roleplay_fail'
      ) then
        raise exception 'fail_content_media_cleanup did not release lease';
      end if;

      select * into v_claim
      from public.claim_content_media_cleanup_batch(1, 600)
      where id = v_claim.id;
      if not found then
        raise exception 'failed cleanup row was not reclaimable';
      end if;
      perform public.complete_content_media_cleanup(
        v_claim.id, v_claim.claim_token
      );
      if exists (
        select 1 from public.content_media_cleanup_queue where id = v_claim.id
      ) then
        raise exception 'complete_content_media_cleanup did not delete row';
      end if;
    end if;
  end loop;
  if v_claim_count <> 1 then
    raise exception 'pending cleanup row was not claimed';
  end if;

  -- Back to admin for remaining article/correction asserts.
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- published edit denial
  begin
    perform public.admin_upsert_reference_article(
      v_article_id, v_ver,
      jsonb_build_object('title', 'Nope')
    );
    raise exception 'expected draft_only on published upsert';
  exception when others then
    if sqlerrm not ilike '%draft%' then
      raise;
    end if;
  end;

  perform set_config('request.jwt.claim.sub', v_student::text, true);
  v_bundle := public.get_my_reference_bundle();
  if jsonb_array_length(v_bundle->'articles') < 1 then
    raise exception 'bundle missing article';
  end if;

  v_corr := public.submit_content_correction(v_article_id, 'Typo in short text');
  if (v_corr->>'ok')::boolean is not true then
    raise exception 'correction failed';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- reject requires reason
  begin
    perform public.admin_resolve_content_correction(
      (v_corr->>'id')::uuid, 'reject', ''
    );
    raise exception 'expected reason_required';
  exception when others then
    if sqlerrm not ilike '%reason%' then
      raise;
    end if;
  end;

  perform public.admin_resolve_content_correction(
    (v_corr->>'id')::uuid, 'reject', 'Not actionable'
  );

  -- restore category association
  v_article := public.admin_restore_content_version(
    v_article_id, v_ver_num, (v_article->>'row_version')::integer
  );
  if (v_article->>'status') is distinct from 'draft' then
    raise exception 'restore must land draft';
  end if;
  if (v_article->>'category_id') is distinct from v_cat_id::text
     and (v_article->>'reference_category_id') is distinct from v_cat_id::text then
    raise exception 'restore lost category';
  end if;

  -- reorder duplicate rejection
  begin
    perform public.admin_reorder_reference_categories(
      array[v_cat_id, v_cat_id],
      array[1, 1]
    );
    raise exception 'expected duplicate_reorder_ids';
  exception when others then
    if sqlerrm not ilike '%duplicate%' then
      raise;
    end if;
  end;

  -- key immutability re-check after later upsert
  v_cat2 := public.admin_upsert_reference_category(
    v_cat_id,
    (v_cat->>'row_version')::integer,
    jsonb_build_object(
      'title', 'Roleplay Cat Renamed',
      'icon_key', 'map',
      'status', 'published',
      'sort_order', 1,
      'key', 'another_mutation'
    )
  );
  if (v_cat2->>'key') is distinct from 'roleplay_cat' then
    raise exception 'category key mutated on later upsert';
  end if;

  raise notice 'stage16_3_reference_hardening_roleplay OK';
end $$;

rollback;
