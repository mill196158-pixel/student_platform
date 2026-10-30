-- All application mutations use guarded RPCs; retain table reads and service access.
revoke insert,update,delete,truncate,references,trigger on public.assignments,public.assignment_done from public,anon,authenticated;
do $$
declare t text; cols text; r text;
begin
  foreach t in array array['assignments','assignment_done'] loop
    select string_agg(quote_ident(column_name),',' order by ordinal_position) into cols
    from information_schema.columns where table_schema='public' and table_name=t;
    execute format('revoke insert (%s), update (%s), references (%s) on table public.%I from public,anon,authenticated',cols,cols,cols,t);
    foreach r in array array['anon','authenticated'] loop
      if has_table_privilege(r,'public.'||t,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        or has_any_column_privilege(r,'public.'||t,'INSERT,UPDATE,REFERENCES') then
        raise exception 'unexpected direct write privilege for % on %',r,t;
      end if;
    end loop;
  end loop;
end $$;
