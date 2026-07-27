-- Stage 13.6 reviews security review.
select c.relname, c.relrowsecurity, c.relforcerowsecurity
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'entity_reviews','review_reports','review_moderation_actions',
    'review_tags','app_feature_flags'
  );

select key, enabled from public.app_feature_flags where key like 'reviews.%';

select indexname from pg_indexes
where schemaname = 'public' and indexname = 'entity_reviews_one_active_uidx';
