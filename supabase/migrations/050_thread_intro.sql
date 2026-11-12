-- Event threads open with an intro: what the thread is for (coordinating, then photos after), the event details,
-- and a tag for everyone signed up as Going. People who sign up later are added to the thread quietly (no ping)
-- at the regular 15-minute check, so it shows in their thread list. Never @everyone.

create table if not exists public.discord_thread_members (
  event_id uuid not null references public.events(id) on delete cascade,
  discord_user_id text not null,
  added_at timestamptz not null default now(),
  primary key (event_id, discord_user_id)
);
alter table public.discord_thread_members enable row level security;

create or replace function public.dc_ensure_thread(p_event uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare e public.events; d public.crew_discord; t text; r jsonb; det jsonb; who text; ids jsonb;
begin
  select thread_id into t from public.discord_threads where event_id = p_event;
  if t is not null then return t; end if;
  select * into e from public.events where id = p_event;
  select * into d from public.crew_discord where crew_id = e.crew_id;
  if e.id is null or not coalesce(d.post_threads, true) or d.bot_token is null or d.channel_id is null then return null; end if;
  r := public.dc_http_json(e.crew_id, 'POST', '/channels/' || d.channel_id || '/threads', jsonb_build_object(
    'name', left(e.title, 80) || ' · ' || to_char(e.event_date, 'FMDy Mon FMDD'), 'type', 11, 'auto_archive_duration', 10080));
  if (r->>'status')::int not between 200 and 299 then return null; end if;
  t := r->'body'->>'id';
  insert into public.discord_threads (event_id, crew_id, thread_id) values (p_event, e.crew_id, t) on conflict (event_id) do nothing;
  det := public.discord_details(d.app_id, p_event);
  select string_agg('<@' || pp.discord_user_id || '>', ' '), coalesce(jsonb_agg(pp.discord_user_id), '[]')
    into who, ids
    from public.event_workers(p_event) w join public.people_private pp on pp.person_id = w
    where pp.discord_user_id is not null;
  perform public.dc_http(e.crew_id, 'POST', '/channels/' || t || '/messages', jsonb_build_object(
    'content', 'This is the event thread for **' || e.title || '**, ' || public.dc_day(e.event_date) || '.' || E'\n'
      || 'Use it to ask questions and coordinate, and post your photos here after the event to be automatically uploaded to LAGB Media Ops.'
      || case when who is not null then E'\n\n' || 'Signed up: ' || who else '' end,
    'embeds', case when det is not null then jsonb_build_array(det) else '[]'::jsonb end,
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array(), 'users', ids)));
  insert into public.discord_thread_members (event_id, discord_user_id)
    select p_event, x from jsonb_array_elements_text(ids) x on conflict do nothing;
  return t;
end $$;
revoke all on function public.dc_ensure_thread(uuid) from public, anon, authenticated;

-- Quietly add later sign-ups to upcoming events' threads.
create or replace function public.dc_thread_sync() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; st int; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  for r in select t.event_id, t.crew_id, t.thread_id, pp.discord_user_id
           from public.discord_threads t join public.events e on e.id = t.event_id
             join public.crew_discord d on d.crew_id = t.crew_id and d.bot_token is not null
             cross join lateral public.event_workers(t.event_id) w
             join public.people_private pp on pp.person_id = w and pp.discord_user_id is not null
           where e.status = 'scheduled' and coalesce(e.end_date, e.event_date) >= today
             and not exists (select 1 from public.discord_thread_members m where m.event_id = t.event_id and m.discord_user_id = pp.discord_user_id)
           limit 20 loop
    st := public.dc_http(r.crew_id, 'PUT', '/channels/' || r.thread_id || '/thread-members/' || r.discord_user_id, null);
    if st between 200 and 299 then
      insert into public.discord_thread_members (event_id, discord_user_id) values (r.event_id, r.discord_user_id) on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.dc_thread_sync() from public, anon, authenticated;

do $$ declare d text; begin
  d := pg_get_functiondef('public.discord_run()'::regprocedure);
  if position('dc_thread_sync' in d) = 0 then
    d := replace(d, 'n := n + public.media_run();', 'n := n + public.media_run();
  n := n + public.dc_thread_sync();');
    if position('dc_thread_sync' in d) = 0 then raise exception 'could not add dc_thread_sync to discord_run'; end if;
    execute d;
  end if;
end $$;
