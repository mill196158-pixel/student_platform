-- Seed academic calendar for VV 2024 import.
-- Scope: public.academic_years and public.academic_terms only.
-- This migration does not transfer staging data and does not touch users,
-- groups, subjects, offerings, teams, chats, or memberships.

insert into public.academic_years(name, start_year, starts_on, ends_on, is_current)
values
  ('2024/2025', 2024, date '2024-09-01', date '2025-08-31', false),
  ('2025/2026', 2025, date '2025-09-01', date '2026-08-31', true)
on conflict do nothing;

insert into public.academic_terms(
  academic_year_id,
  term_in_year,
  term_sequence,
  name,
  preload_starts_on,
  starts_on,
  ends_on,
  is_current
)
select
  ay.id,
  term_data.term_in_year,
  term_data.term_sequence,
  term_data.name,
  term_data.preload_starts_on,
  term_data.starts_on,
  term_data.ends_on,
  term_data.is_current
from (
  values
    ('2024/2025', 1, 20241, 'осень 2024', null::date, date '2024-09-01', date '2025-01-31', false),
    ('2024/2025', 2, 20242, 'весна 2025', null::date, date '2025-02-01', date '2025-06-30', false),
    ('2025/2026', 1, 20251, 'осень 2025', null::date, date '2025-09-01', date '2026-01-31', false),
    ('2025/2026', 2, 20252, 'весна 2026', null::date, date '2026-02-01', date '2026-06-30', true)
) as term_data(academic_year_name, term_in_year, term_sequence, name, preload_starts_on, starts_on, ends_on, is_current)
join public.academic_years ay on ay.name = term_data.academic_year_name
on conflict do nothing;
