-- Event threads are named date first ("11-29 Hollywood Christmas Parade") and follow date/title changes.
alter table public.discord_threads add column if not exists name text;

create or replace function public.dc_thread_name(p_date date, p_title text)
returns text language sql immutable set search_path to '' as $$
  select to_char(p_date, 'MM-DD') || ' ' || left(p_title, 90)
$$;

create or replace function public.dc_thread_names()
returns integer language plpgsql security definer set search_path to '' as $function$
declare r record; n int := 0; st int; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  for r in
    select t.event_id, t.crew_id, t.thread_id, public.dc_thread_name(e.event_date, e.title) as want
    from public.discord_threads t join public.events e on e.id = t.event_id
      join public.crew_discord d on d.crew_id = t.crew_id and d.bot_token is not null
    where e.status = 'scheduled' and not e.date_tbd
      and coalesce(e.end_date, e.event_date) >= today - 7
      and t.name is distinct from public.dc_thread_name(e.event_date, e.title)
    -- past ones first, then farthest date first, so the closest upcoming event is renamed last and sits on top
    order by (coalesce(e.end_date, e.event_date) < today) desc, e.event_date desc
    limit 10 loop
    st := public.dc_http(r.crew_id, 'PATCH', '/channels/' || r.thread_id, jsonb_build_object('name', r.want));
    if st between 200 and 299 then
      update public.discord_threads set name = r.want where event_id = r.event_id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

revoke all on function public.dc_thread_names() from public, anon, authenticated;

do $do$
declare def text; new text;
begin
  -- new threads: date-first name, and remember it
  select pg_get_functiondef('public.dc_ensure_thread(uuid)'::regprocedure) into def;
  new := replace(def, $a$left(e.title, 80) || ' · ' || to_char(e.event_date, 'FMDy Mon FMDD')$a$, $b$public.dc_thread_name(e.event_date, e.title)$b$);
  if new = def then raise exception 'dc_ensure_thread: name expression not found'; end if;
  def := new;
  new := replace(def, $a$insert into public.discord_threads (event_id, crew_id, thread_id) values (p_event, e.crew_id, t)$a$,
                      $b$insert into public.discord_threads (event_id, crew_id, thread_id, name) values (p_event, e.crew_id, t, public.dc_thread_name(e.event_date, e.title))$b$);
  if new = def then raise exception 'dc_ensure_thread: insert not found'; end if;
  execute new;

  -- 15-minute runner keeps names current
  select pg_get_functiondef('public.discord_run()'::regprocedure) into def;
  new := replace(def, 'n := n + public.dc_thread_sync();', 'n := n + public.dc_thread_sync();' || E'\n' || '  n := n + public.dc_thread_names();');
  if new = def then raise exception 'discord_run: hook not found'; end if;
  execute new;
end $do$;
