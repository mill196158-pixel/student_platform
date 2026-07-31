-- Stage 14.2.2: allow working-draft schema upgrade home_promo/profile_feed 1→2.
-- Visual Content Studio always edits schema v2 payloads; published legacy cards
-- remain schema_version=1 until WD publish. Publish of schema 2 is still gated by
-- content_visual_studio_v2_publish (content_assert_v2_publish_allowed).
-- Does not mutate existing rows. Does not enable/disable the feature flag.

create or replace function private.content_working_draft_effective_schema(
  p_canonical_template text,
  p_canonical_schema integer,
  p_target integer
)
returns integer
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_target is null then
    return p_canonical_schema;
  end if;

  -- Reference article: existing 1|2 → 3 path.
  if p_canonical_template = 'reference_article_v1'
     and p_canonical_schema in (1, 2)
     and p_target = 3 then
    return 3;
  end if;

  -- Home / Profile Visual Studio: prepare schema 2 on a schema 1 canonical.
  if p_canonical_template in ('home_promo_v1', 'profile_feed_card_v1')
     and p_canonical_schema = 1
     and p_target = 2 then
    return 2;
  end if;

  if p_target = p_canonical_schema then
    return p_target;
  end if;

  raise exception 'invalid_schema_upgrade' using errcode = '22023';
end;
$$;

revoke all on function private.content_working_draft_effective_schema(text, integer, integer)
  from public, anon, authenticated;
grant execute on function private.content_working_draft_effective_schema(text, integer, integer)
  to service_role;

comment on function private.content_working_draft_effective_schema(text, integer, integer) is
  'Stage 14.2.2: WD effective schema; allows home_promo_v1/profile_feed_card_v1 1→2 and reference →3.';
