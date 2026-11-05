-- Owner-authorized public Base projections. No raw table privileges are added.
-- Subject publication is explicit; existing diagnostic subjects are not seeded.
alter table public.subject_catalog add column if not exists guest_visible boolean not null default false;
alter table public.content_items add column if not exists guest_visible boolean not null default false;
alter table public.vacancies add column if not exists guest_visible boolean not null default false;
update public.content_items set guest_visible=true where template_key='reference_article_v1' and status='published' and audience_mode='all' and title in ('Как заказать справку','Как установить нужные программы','Карта и аудитории','Частые вопросы','Как скачать нужные материалы','Как зайти в личный кабинет');
update public.subject_catalog set guest_visible=true
where status='published' and description is null
  and canonical_name in ('Деловой иностранный язык','Инженерно-технологическая реконструкция систем водоотведения','Инженерно-технологическая реконструкция систем водоснабжения','Информационное моделирование в профессиональной сфере (ТИМ)','Командообразование, самоуправление и социальная адаптация в профессиональной деятельности','Моделирование систем водоснабжения и водоотведения','Надежность систем водоснабжения и водоотведения','Научно-исследовательская работа','Ознакомительная практика','Организация проектно-изыскательской деятельности','Организация производственной деятельности','Организация эксплуатации систем и сооружений водоснабжения и водоотведения','Основы научно-профессиональной коммуникации','Основы научных исследований','Основы системного анализа и теории принятия решений','Охрана водных ресурсов','Подготовка к процедуре защиты и защита выпускной квалификационной работы','Практические основы анализа больших данных и визуализации результатов','Прикладная математика','Проектная практика. Часть 1','Проектная практика. Часть 2','Проектный менеджмент','Системы и сооружения водоотведения','Системы и сооружения водоснабжения','Социальные коммуникации. Психология','Технологии прокладки инженерных сетей','Управление строительной организацией');

create or replace function public.get_guest_base(p_section text, p_query text default '', p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare q text := left(coalesce(p_query,''),120); off integer := greatest(0,least(coalesce(p_offset,0),10000)); result jsonb;
begin
if p_section='subjects' then
 select coalesce(jsonb_agg(t.data order by t.title,t.id),'[]'::jsonb) into result from (
 select s.id,s.canonical_name title,jsonb_build_object('id',s.id,'title',s.canonical_name,
 'description',s.description,'control_form',s.control_form,'department',s.department,
 'requirements',s.requirements,'learning_outcomes',s.learning_outcomes) data
 from public.subject_catalog s where s.guest_visible and s.status='published' and s.archived_at is null
 and (q='' or strpos(lower(s.canonical_name),lower(q))>0)
 order by s.canonical_name,s.id limit 50 offset off) t;
elsif p_section='help' then
 select coalesce(jsonb_agg(t.data order by t.title,t.id),'[]'::jsonb) into result from (
 select i.id,i.title,jsonb_build_object('id',i.id,'title',i.title,'template_key',i.template_key,
 'schema_version',3,'origin',i.origin,'category_id',c.id,'category_title',c.title,
 'payload',jsonb_build_object('icon_key',coalesce(i.payload->>'icon_key','help'),
 'short_text',i.payload->>'short_text','blocks',coalesce((select jsonb_agg(
 case when b->>'type'='list' then jsonb_build_object('type','list','items',coalesce((select jsonb_agg(x) from jsonb_array_elements(case when jsonb_typeof(b->'items')='array' then b->'items' else '[]'::jsonb end) x where jsonb_typeof(x)='string'),'[]'::jsonb))
 else jsonb_strip_nulls(jsonb_build_object('type',b->>'type','text',b->>'text','level',case when b->>'level' in ('1','2','3') then (b->>'level')::integer else null end)) end)
 from jsonb_array_elements(case when jsonb_typeof(i.payload->'blocks')='array' then i.payload->'blocks' else '[]'::jsonb end) b
 where b->>'type' in ('text','heading','info','warning','list')),'[]'::jsonb))) data
 from public.content_items i
 join lateral (select rc.id,rc.title from public.content_item_reference_categories l
 join public.reference_categories rc on rc.id=l.reference_category_id
 where l.content_item_id=i.id and rc.status='published' and not coalesce(rc.is_hidden,false)
 order by rc.sort_order,rc.id limit 1) c on true
 where i.guest_visible and i.template_key='reference_article_v1' and i.status='published' and not i.is_hidden
 and i.audience_mode='all' and (i.starts_at is null or i.starts_at<=now()) and (i.ends_at is null or i.ends_at>now())
 and exists(select 1 from public.content_item_placements p where p.content_item_id=i.id and p.placement='reference')
 and not exists(select 1 from public.content_item_audience_groups a where a.content_item_id=i.id)
 and not exists(select 1 from public.content_item_audience_users a where a.content_item_id=i.id)
 and (q='' or strpos(lower(i.title),lower(q))>0)
 order by i.title,i.id limit 50 offset off) t;
elsif p_section='jobs' then
 select coalesce(jsonb_agg(t.data order by t.title,t.id),'[]'::jsonb) into result from (
 select v.id,v.title,jsonb_build_object('id',v.id,'title',v.title,'company_name',v.company_name,
 'summary',v.summary,'description',v.description,'employment_type',v.employment_type,
 'work_format',v.work_format,'location',v.location,'salary_text',v.salary_text,'origin',v.origin,
 'published_at',v.published_at,'expires_at',v.expires_at,'has_contacts',v.contacts<>'{}'::jsonb) data
 from public.vacancies v where v.guest_visible and v.status='published' and not v.is_hidden and v.audience_mode='all'
 and (v.starts_at is null or v.starts_at<=now()) and (v.ends_at is null or v.ends_at>now())
 and (v.expires_at is null or v.expires_at>now())
 and not exists(select 1 from public.vacancy_audience_groups a where a.vacancy_id=v.id)
 and not exists(select 1 from public.vacancy_audience_users a where a.vacancy_id=v.id)
 and (q='' or strpos(lower(v.title||' '||coalesce(v.company_name,'')),lower(q))>0)
 order by v.title,v.id limit 50 offset off) t;
else raise exception 'invalid_section' using errcode='22023'; end if;
return result;
end $$;
revoke all on function public.get_guest_base(text,text,integer) from public,anon,authenticated;
grant execute on function public.get_guest_base(text,text,integer) to anon,authenticated;
