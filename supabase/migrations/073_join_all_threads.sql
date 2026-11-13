-- "Join every event thread" is a personal setting (Me tab, Settings) for webmasters and crew admins. It is off by
-- default; Bill and Jeff Gritton start with it on. People are still added to threads for events they answer Going to.

alter table public.people_private add column if not exists join_all_threads boolean not null default false;
update public.people_private set join_all_threads = true
where person_id in ('f8805dc5-e7e4-46d5-a91e-049bc9987f4a', '549efb01-7752-4624-bf16-e68861e38e3a');

-- Thread sync: webmasters and crew admins only when they have the setting on.
do $$
declare d text := pg_get_functiondef('public.dc_thread_sync()'::regprocedure);
  f text := $x$join public.people_private pp on pp.person_id = p.id and pp.discord_user_id is not null)$x$;
begin
  if position('join_all_threads' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'dc_thread_sync: line not found once'; end if;
  execute replace(d, f, $x$join public.people_private pp on pp.person_id = p.id and pp.discord_user_id is not null and pp.join_all_threads)$x$);
end $$;

-- Saving My details can turn it on or off.
do $$
declare d text := pg_get_functiondef('public.save_my_details(uuid,jsonb)'::regprocedure);
  f text := $x$share_email = coalesce((p->>'share_email')::boolean, share_email)$x$;
begin
  if position('join_all_threads' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'save_my_details: share_email line not found once'; end if;
  execute replace(d, f, f || $x$, join_all_threads = coalesce((p->>'join_all_threads')::boolean, join_all_threads)$x$);
end $$;

-- my_session returns it.
do $$
declare d text := pg_get_functiondef('public.my_session(uuid)'::regprocedure);
  f text := $x$pp.share_phone, pp.share_email$x$;
begin
  if position('pp.join_all_threads' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'my_session: share columns not found once'; end if;
  execute replace(d, f, f || ', pp.join_all_threads');
end $$;
