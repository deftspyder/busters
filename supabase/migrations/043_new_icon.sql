-- New Busters icon (Nov 11): bump the icon link so Discord fetches the new picture instead of its cached one.
do $$ declare r record; begin
  for r in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
           and pg_get_functiondef(p.oid) like '%icons/icon-192.png''%' loop
    execute replace(pg_get_functiondef(r.oid), 'icons/icon-192.png''', 'icons/icon-192.png?v=3''');
  end loop;
end $$;
