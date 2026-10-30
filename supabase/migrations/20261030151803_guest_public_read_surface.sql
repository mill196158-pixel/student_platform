-- Explicit guest publication is separate from the existing student audience.
alter table public.news_posts add column if not exists guest_visible boolean not null default false;
update public.news_posts n set guest_visible=true where n.id='9658bbcf-7fc8-48cc-ae1f-21b1a0ad1523'::uuid and n.title='Новое приложение' and (n.starts_at is null or n.starts_at<=now()) and (n.ends_at is null or n.ends_at>=now()) and status='published' and not is_hidden and audience_type='all' and audience_group_id is null and not exists(select 1 from public.news_audience_groups g where g.news_post_id=n.id) and not exists(select 1 from public.news_audience_users u where u.news_post_id=n.id);
create or replace function public.get_guest_news() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from (
 select n.id,n.title,n.subtitle,n.body,n.variant,n.gradient_colors,n.image_path,n.image_focus_x,n.image_focus_y,n.overlay_opacity,n.published_at,n.updated_at,n.version_number
 from public.news_posts n where n.guest_visible and n.status='published' and not n.is_hidden and n.audience_type='all' and n.audience_group_id is null
 and (n.starts_at is null or n.starts_at<=now()) and (n.ends_at is null or n.ends_at>=now())
 and not exists(select 1 from public.news_audience_groups g where g.news_post_id=n.id)
 and not exists(select 1 from public.news_audience_users u where u.news_post_id=n.id)
 order by n.sort_order,n.priority desc,n.published_at desc limit 30) x;
$$;
create table if not exists private.guest_public_groups (group_id uuid primary key references public.groups(id) on delete cascade);
alter table private.guest_public_groups enable row level security;
revoke all on private.guest_public_groups from public,anon,authenticated;
insert into private.guest_public_groups(group_id) select id from public.groups where name in ('1-См(ВВ)-2','2-См(ВВ)-2') on conflict do nothing;
create or replace function public.get_guest_groups() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (select g.id,g.name from public.groups g where exists(select 1 from private.guest_public_groups pg where pg.group_id=g.id) order by g.name limit 500) x;
$$;
create or replace function public.get_guest_lessons(p_group uuid,p_from date) returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
 select l.id,l.date,l.pair_num,l.time_start,l.time_end,l.subject,l.room from public.lessons l
 where exists(select 1 from public.groups g where g.id=l.group_id and exists(select 1 from private.guest_public_groups pg where pg.group_id=g.id)) and l.group_id=p_group and l.date>=p_from and l.date<p_from+7 order by l.date,l.time_start limit 200) x;
$$;
revoke all on function public.get_guest_news(),public.get_guest_groups(),public.get_guest_lessons(uuid,date) from public;
grant execute on function public.get_guest_news(),public.get_guest_groups(),public.get_guest_lessons(uuid,date) to anon,authenticated;
-- Only cover images belonging to currently public news. Bucket remains private.
create policy guest_news_cover_read on storage.objects for select to anon
 using(bucket_id='news-media' and storage.allow_only_operation('object.get_authenticated') and exists(select 1 from jsonb_array_elements(public.get_guest_news()) n where n->>'image_path'=name));
