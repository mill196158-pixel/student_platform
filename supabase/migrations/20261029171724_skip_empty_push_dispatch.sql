do $migration$
declare j record; wrapped text;
begin
select jobid,command,schedule into strict j from cron.job where jobname='dispatch-push-notifications-minutely';
if j.command like '%student_idle_push_v1%' then return; end if;
if j.schedule <> '* * * * *' or j.command !~* '^\s*select\s+net\.http_post' then raise exception 'Unexpected cron definition'; end if;
wrapped := format($wrapper$
do $idle_push$
begin
-- student_idle_push_v1
if exists(select 1 from public.notification_outbox where
(status='pending' and attempts<8 and available_at<=now()) or
(status='processing' and processing_started_at<=now()-interval '5 minutes'))
then execute %L; end if;
end $idle_push$;
$wrapper$,j.command);
perform cron.alter_job(j.jobid,command:=wrapped);
end $migration$;
