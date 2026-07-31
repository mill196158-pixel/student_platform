-- Stage 14.2: project student READ wire schema_version for home/profile.
-- Stored schema_version 2 is returned as wire 1 so legacy Mobile clients
-- (tryParseHomePromo schema==1 only) still parse cards. Payload keeps v2
-- dual-read fields (home_slot, card_variant, action, focal, …).
-- Does NOT enable content_visual_studio_v2_publish (owner SQL only).

create or replace function public.get_my_content_for_placement(p_placement text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_placement text := nullif(btrim(coalesce(p_placement, '')), '');
  v_groups uuid[];
  v_eligible boolean;
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if v_placement is null
     or v_placement not in ('home_promo', 'profile_feed', 'reference') then
    raise exception 'invalid_placement' using errcode = '22023';
  end if;

  if not exists (select 1 from public.users u where u.id = v_uid and u.is_active) then
    return '[]'::jsonb;
  end if;

  v_groups := private.current_user_active_group_ids();
  v_eligible := coalesce(array_length(v_groups, 1), 0) > 0;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', ci.id,
          'template_key', ci.template_key,
          -- Legacy-safe wire: present schema 2 home/profile as schema 1.
          'schema_version', case
            when ci.template_key in ('home_promo_v1', 'profile_feed_card_v1')
                 and ci.schema_version = 2
              then 1
            else ci.schema_version
          end,
          'placement', pl.placement,
          'sort_order', pl.sort_order,
          'priority', ci.priority,
          'origin', ci.origin,
          'title', ci.title,
          'payload', ci.payload,
          'dismissible', coalesce((ci.payload ->> 'dismissible')::boolean, false),
          'starts_at', ci.starts_at,
          'ends_at', ci.ends_at,
          'published_at', ci.published_at
        )
        order by pl.sort_order, ci.priority desc, ci.published_at desc nulls last
      )
      from public.content_items ci
      join public.content_item_placements pl
        on pl.content_item_id = ci.id
       and pl.placement = v_placement
      left join public.content_item_dismissals d
        on d.content_item_id = ci.id
       and d.user_id = v_uid
      where ci.status = 'published'
        and not ci.is_hidden
        and (ci.starts_at is null or ci.starts_at <= v_now)
        and (ci.ends_at is null or ci.ends_at > v_now)
        and (
          d.content_item_id is null
          or (d.can_reshow_after is not null and d.can_reshow_after <= v_now)
        )
        and (
          (ci.audience_mode = 'all' and v_eligible)
          or (
            ci.audience_mode in ('groups', 'groups_and_users')
            and exists (
              select 1
              from public.content_item_audience_groups g
              where g.content_item_id = ci.id
                and g.group_id = any (v_groups)
            )
          )
          or (
            ci.audience_mode in ('users', 'groups_and_users')
            and v_eligible
            and exists (
              select 1
              from public.content_item_audience_users au
              where au.content_item_id = ci.id
                and au.user_id = v_uid
            )
          )
        )
    ),
    '[]'::jsonb
  );
end;
$$;

comment on function public.get_my_content_for_placement(text) is
  'Student placement feed. Stage 14.2: wire schema_version for home_promo_v1/profile_feed_card_v1 schema 2 is projected to 1 for legacy clients; payload retains dual-read v2 fields.';
