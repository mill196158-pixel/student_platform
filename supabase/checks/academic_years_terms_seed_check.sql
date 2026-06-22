-- Read-only check for VV 2024 academic calendar seed.
-- This file intentionally contains SELECT statements only.

-- 1. Academic years for VV 2024 import.
select
  id,
  name,
  start_year,
  starts_on,
  ends_on,
  is_current,
  created_at
from public.academic_years
where name in ('2024/2025', '2025/2026')
   or start_year in (2024, 2025)
order by start_year, name;

-- 2. Academic terms for 2024/2025 and 2025/2026.
select
  ay.id as academic_year_id,
  ay.name as academic_year_name,
  at.id as academic_term_id,
  at.term_in_year,
  at.term_sequence,
  at.name as academic_term_name,
  at.preload_starts_on,
  at.starts_on,
  at.ends_on,
  at.is_current,
  at.created_at
from public.academic_terms at
join public.academic_years ay on ay.id = at.academic_year_id
where ay.name in ('2024/2025', '2025/2026')
   or ay.start_year in (2024, 2025)
order by ay.start_year, at.term_sequence, at.term_in_year;

-- 3. Summary: expected two years and four terms.
select
  count(distinct ay.id)::bigint as academic_years_count,
  count(at.id)::bigint as academic_terms_count
from public.academic_years ay
left join public.academic_terms at on at.academic_year_id = ay.id
where ay.name in ('2024/2025', '2025/2026')
   or ay.start_year in (2024, 2025);

-- 4. Current VV 2024 term: spring 2026.
select
  ay.id as academic_year_id,
  ay.name as academic_year_name,
  at.id as academic_term_id,
  at.term_in_year,
  at.term_sequence,
  at.name as academic_term_name,
  at.starts_on,
  at.ends_on,
  at.is_current
from public.academic_terms at
join public.academic_years ay on ay.id = at.academic_year_id
where ay.name = '2025/2026'
  and at.term_in_year = 2
  and at.term_sequence = 20252;
