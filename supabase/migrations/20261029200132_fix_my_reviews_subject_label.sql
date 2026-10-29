CREATE OR REPLACE FUNCTION public.get_my_entity_reviews(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'review_id', x.id,
          'entity_type', x.entity_type,
          'entity_id', x.entity_id,
          'entity_label', x.entity_label,
          'tag_scores', x.tag_scores,
          'body_text', x.body_text,
          'moderation_status', x.moderation_status,
          'moderation_reason', x.moderation_reason,
          'status', x.status,
          'updated_at', x.updated_at
        )
        order by x.updated_at desc
      )
      from (
        select
          r.id,
          r.entity_type,
          r.entity_id,
          case
            when r.entity_type = 'teacher' then coalesce(
              nullif(btrim(t.full_name), ''), 'Преподаватель')
            else coalesce(
              nullif(btrim(sc.canonical_name), ''),
              'Предмет')
          end as entity_label,
          r.tag_scores,
          r.body_text,
          r.moderation_status,
          r.moderation_reason,
          r.status,
          r.updated_at
        from public.entity_reviews r
        left join public.teachers t
          on r.entity_type = 'teacher' and t.id = r.entity_id
        left join public.subject_catalog sc
          on r.entity_type = 'subject' and sc.id = r.entity_id
        where r.author_user_id = v_uid
          and r.status <> 'removed'
        order by r.updated_at desc
        limit v_limit
      ) x
    ),
    '[]'::jsonb
  );
end;
$function$
;
