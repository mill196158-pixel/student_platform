-- Owner confirmed nominal Sep 1 / Feb 1 boundaries. Reference rows only:
-- no is_current switch, archive transition or scheduled auto-activation.
insert into public.academic_years(name,start_year,starts_on,ends_on,is_current)
values('2026/27',2026,'2026-09-01','2027-08-31',false)
on conflict(start_year) do nothing;
insert into public.academic_terms(academic_year_id,term_in_year,term_sequence,name,starts_on,ends_on,is_current,auto_activation_enabled)
select y.id,v.n,v.seq,v.name,v.starts,v.ends,false,false
from public.academic_years y cross join (values
 (1,20261,'Осень 2026',date '2026-09-01',date '2027-01-31'),
 (2,20262,'Весна 2027',date '2027-02-01',date '2027-08-31')) v(n,seq,name,starts,ends)
where y.start_year=2026
on conflict(academic_year_id,term_in_year) do nothing;
