do $$ declare r record; begin
  for r in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
           and pg_get_functiondef(p.oid) like '%icon-192.png?v=3%' loop
    execute replace(pg_get_functiondef(r.oid), 'icon-192.png?v=3', 'icon-192.png?v=4');
  end loop;
end $$;
