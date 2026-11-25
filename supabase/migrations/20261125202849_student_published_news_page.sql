begin;

create index if not exists news_posts_published_page_idx
  on public.news_posts(sort_order, priority desc, published_at desc nulls last, id)
  where status = 'published' and not is_hidden;

-- Use the same eligibility, audience and scheduling rules as get_my_published_news.
-- Only the checked page is serialized. The extra row indicates another page.
create or replace function public.get_my_published_news_page(
  p_limit integer default 20, p_after jsonb default null
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  viewer uuid := auth.uid();
  after_id uuid := (p_after->>'id')::uuid;
  after_sort integer := (p_after->>'sort_order')::integer;
  after_priority integer := (p_after->>'priority')::integer;
  after_published timestamptz := (p_after->>'published_at')::timestamptz;
begin
  if viewer is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_limit is null or p_limit not between 1 and 50 or
     (p_after is not null and (after_id is null or after_sort is null or
      after_priority is null or not (p_after ? 'published_at'))) then
    raise exception 'invalid_news_page' using errcode = '22023';
  end if;

  return (
    select coalesce(jsonb_agg(to_jsonb(page) order by page.sort_order,
      page.priority desc, page.published_at desc nulls last, page.id), '[]'::jsonb)
    from (
      select n.id, n.sort_order, n.priority, n.published_at, n.created_at, n.updated_at,
             n.title, n.subtitle, n.body, n.variant, n.gradient_colors, n.image_path,
             n.image_focus_x, n.image_focus_y, n.overlay_opacity
      from public.news_posts n
      where n.status = 'published' and not n.is_hidden
        and (n.starts_at is null or n.starts_at <= now())
        and (n.ends_at is null or n.ends_at >= now())
        and private.news_audience_matches(n.id, viewer)
        and (p_after is null or n.sort_order > after_sort
          or (n.sort_order = after_sort and (n.priority < after_priority
            or (n.priority = after_priority and (
              (after_published is not null and
               (n.published_at < after_published or n.published_at is null))
              or (n.published_at is not distinct from after_published and n.id > after_id)
            )))))
      order by n.sort_order, n.priority desc, n.published_at desc nulls last, n.id
      limit p_limit + 1
    ) page
  );
end;
$$;
revoke all on function public.get_my_published_news_page(integer,jsonb) from public, anon;
grant execute on function public.get_my_published_news_page(integer,jsonb) to authenticated, service_role;

commit;
