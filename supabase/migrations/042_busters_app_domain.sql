-- Busters moved to https://busters.app (Nov 10). Point every stored link, icon and user agent at it.
do $$ declare r record; d text; begin
  for r in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
           and pg_get_functiondef(p.oid) like '%deftspyder.github.io/busters%' loop
    d := replace(pg_get_functiondef(r.oid), 'deftspyder.github.io/busters', 'busters.app');
    execute d;
  end loop;
end $$;
