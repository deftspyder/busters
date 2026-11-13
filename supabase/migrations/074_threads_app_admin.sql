-- "Join every event thread" also works for app admins (Bill), who aren't webmasters or crew admins in the crew.
do $$
declare d text := pg_get_functiondef('public.dc_thread_sync()'::regprocedure);
  f text := $x$and p.abilities && array['webmaster', 'crew_admin']$x$;
begin
  if position('app_admin_emails' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'dc_thread_sync: abilities line not found once'; end if;
  execute replace(d, f, $x$and (p.abilities && array['webmaster', 'crew_admin'] or exists (select 1 from auth.users u join public.app_admin_emails a on lower(a.email) = lower(u.email) where u.id = p.user_id))$x$);
end $$;
