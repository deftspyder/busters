-- Busters events in Discord's own Events list (the server's scheduled events), kept in sync, plus a one-time
-- DM to anyone who taps "Interested" there without having answered in Busters. "Interested" is a hint, not an
-- answer. The bot only needs Create Events (the LAGB server gives that to everyone), which lets it edit and
-- remove the events it made.

alter table public.crew_discord
  add column if not exists post_events boolean not null default true,
  add column if not exists dm_interested boolean not null default true;

create table if not exists public.discord_sched (
  event_id uuid primary key,          -- no FK on purpose: if an event is deleted we still need this row to remove it
  crew_id uuid not null references public.crews(id) on delete cascade,
  sched_id text not null,
  hash text,
  synced_at timestamptz not null default now()
);
alter table public.discord_sched enable row level security;

create table if not exists public.discord_interest (
  event_id uuid not null,
  discord_user_id text not null,
  status int,
  at timestamptz not null default now(),
  primary key (event_id, discord_user_id)
);
alter table public.discord_interest enable row level security;

-- What the Discord event looks like. Counts are left out on purpose so it only changes when the event does.
create or replace function public.dc_sched_payload(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.events; pl record; tz text := 'America/Los_Angeles'; st timestamptz; en timestamptz; loc text; descr text;
begin
  select * into e from public.events where id = p_event;
  select * into pl from public.dc_primary_place(p_event);
  st := ((e.event_date + coalesce(e.call_time, e.start_time, time '09:00'))::timestamp at time zone tz);
  en := ((coalesce(e.end_date, e.event_date) + coalesce(e.wrap_time, time '00:00'))::timestamp at time zone tz);
  if e.wrap_time is null or en <= st then en := st + interval '4 hours'; end if;
  loc := coalesce(left(pl.name || coalesce(', ' || pl.address, ''), 100), 'Location coming soon');
  descr := public.dc_day(e.event_date)
    || coalesce(' · Call ' || public.dc_t(e.call_time), '')
    || coalesce(' · ' || public.dc_trange(e.start_time, e.wrap_time), '')
    || E'\n\nTap Interested to follow it here, and answer Going / Maybe / Can''t on the Busters card in the channel.';
  return jsonb_build_object('name', left(e.title, 100), 'privacy_level', 2, 'entity_type', 3,
    'entity_metadata', jsonb_build_object('location', loc),
    'scheduled_start_time', to_char(st at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'scheduled_end_time', to_char(en at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'description', left(descr, 1000));
end $$;
revoke all on function public.dc_sched_payload(uuid) from public, anon, authenticated;

-- Keep the Events list in step with Busters (runs every 15 minutes; Discord events are silent, so any hour).
create or replace function public.dc_sched_sync() returns int
language plpgsql security definer set search_path = '' as $$
declare d record; r record; p jsonb; h text; res jsonb; calls int; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  for d in select * from public.crew_discord where bot_token is not null and guild_id is not null loop
    calls := 0;
    -- remove ones that are no longer upcoming scheduled events (cancelled, deleted, proposed again)
    for r in select s.* from public.discord_sched s left join public.events e on e.id = s.event_id
             where s.crew_id = d.crew_id and (e.id is null or e.status <> 'scheduled' or not d.post_events) loop
      exit when calls >= 10;
      res := public.dc_http_json(d.crew_id, 'DELETE', '/guilds/' || d.guild_id || '/scheduled-events/' || r.sched_id, null);
      calls := calls + 1;
      if (res->>'status')::int in (200, 204, 404) then delete from public.discord_sched where event_id = r.event_id; n := n + 1; end if;
    end loop;
    -- forget ones that have finished (Discord wraps them up itself)
    delete from public.discord_sched s using public.events e
      where s.event_id = e.id and s.crew_id = d.crew_id and coalesce(e.end_date, e.event_date) < today - 1;
    continue when not d.post_events;
    for r in select e.id, s.sched_id, s.hash from public.events e left join public.discord_sched s on s.event_id = e.id
             where e.crew_id = d.crew_id and e.status = 'scheduled' and e.event_date between today and today + 60
             order by e.event_date loop
      exit when calls >= 10;
      p := public.dc_sched_payload(r.id);
      continue when (p->>'scheduled_start_time')::timestamptz <= now();
      h := md5(p::text);
      continue when r.hash = h;
      if r.sched_id is null then
        res := public.dc_http_json(d.crew_id, 'POST', '/guilds/' || d.guild_id || '/scheduled-events', p);
        if (res->>'status')::int between 200 and 299 then
          insert into public.discord_sched (event_id, crew_id, sched_id, hash) values (r.id, d.crew_id, res->'body'->>'id', h);
          n := n + 1;
        end if;
      else
        res := public.dc_http_json(d.crew_id, 'PATCH', '/guilds/' || d.guild_id || '/scheduled-events/' || r.sched_id, p);
        if (res->>'status')::int between 200 and 299 then
          update public.discord_sched set hash = h, synced_at = now() where event_id = r.id; n := n + 1;
        elsif (res->>'status')::int = 404 then
          delete from public.discord_sched where event_id = r.id;       -- someone removed it in Discord; recreate next run
        end if;
      end if;
      calls := calls + 1;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.dc_sched_sync() from public, anon, authenticated;

-- One DM per person per event to anyone who taps Interested but hasn't answered in Busters.
create or replace function public.dc_interest_dms() returns int
language plpgsql security definer set search_path = '' as $$
declare d record; r record; u jsonb; res jsonb; dm text; pid uuid; n int := 0; calls int; st int; ttl text;
begin
  for d in select * from public.crew_discord where bot_token is not null and guild_id is not null and post_events and dm_interested loop
    continue when public.dc_quiet(d.quiet_from, d.quiet_to);
    calls := 0;
    for r in select s.event_id, s.sched_id, e.title from public.discord_sched s join public.events e on e.id = s.event_id
             where s.crew_id = d.crew_id and e.status = 'scheduled' and e.event_date >= (now() at time zone 'America/Los_Angeles')::date loop
      exit when calls >= 12;
      res := public.dc_http_json(d.crew_id, 'GET', '/guilds/' || d.guild_id || '/scheduled-events/' || r.sched_id || '/users?limit=100', null);
      calls := calls + 1;
      continue when (res->>'status')::int <> 200 or jsonb_typeof(res->'body') <> 'array';
      for u in select * from jsonb_array_elements(res->'body') loop
        continue when coalesce((u->'user'->>'bot')::boolean, false);
        continue when exists (select 1 from public.discord_interest i where i.event_id = r.event_id and i.discord_user_id = u->'user'->>'id');
        select pp.person_id into pid from public.people_private pp where pp.crew_id = d.crew_id and pp.discord_user_id = u->'user'->>'id';
        if pid is not null and exists (select 1 from public.rsvps x where x.event_id = r.event_id and x.person_id = pid) then
          insert into public.discord_interest (event_id, discord_user_id, status) values (r.event_id, u->'user'->>'id', 0) on conflict do nothing;
          continue;
        end if;
        exit when calls >= 12;
        res := public.dc_http_json(d.crew_id, 'POST', '/users/@me/channels', jsonb_build_object('recipient_id', u->'user'->>'id'));
        calls := calls + 1;
        dm := res->'body'->>'id'; st := (res->>'status')::int;
        if dm is not null then
          st := public.dc_http(d.crew_id, 'POST', '/channels/' || dm || '/messages', jsonb_build_object(
            'content', 'Saw you''re interested in **' || r.title || '**. Are you in?',
            'embeds', jsonb_build_array(public.dc_embed(r.event_id, 'interest', null)),
            'components', public.dc_buttons(r.event_id),
            'allowed_mentions', jsonb_build_object('parse', jsonb_build_array())));
          calls := calls + 1;
        end if;
        insert into public.discord_interest (event_id, discord_user_id, status) values (r.event_id, u->'user'->>'id', st) on conflict do nothing;
        n := n + 1;
      end loop;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.dc_interest_dms() from public, anon, authenticated;

-- Card header for the DM, runner hooks, and the switches on the schedule page.
do $$ declare d text; begin
  d := pg_get_functiondef('public.dc_embed(uuid,text,text)'::regprocedure);
  if position('''interest''' in d) = 0 then
    d := replace(d, $x$when 'cancelled' then '❌ Cancelled' else null end;$x$, $x$when 'cancelled' then '❌ Cancelled' when 'interest' then '👀 You''re interested' else null end;$x$);
    execute d;
  end if;
  d := pg_get_functiondef('public.discord_run()'::regprocedure);
  if position('dc_sched_sync' in d) = 0 then
    d := replace(d, 'n := n + public.dc_giveback_milestones();', 'n := n + public.dc_giveback_milestones();
  n := n + public.dc_sched_sync();
  n := n + public.dc_interest_dms();');
    execute d;
  end if;
  d := pg_get_functiondef('public.discord_schedule(uuid)'::regprocedure);
  if position('post_events' in d) = 0 then
    d := replace(d, $x$'post_threads', coalesce(d.post_threads, true),$x$, $x$'post_threads', coalesce(d.post_threads, true), 'post_events', coalesce(d.post_events, true), 'dm_interested', coalesce(d.dm_interested, true),$x$);
    execute d;
  end if;
  d := pg_get_functiondef('public.set_discord_schedule(uuid,jsonb)'::regprocedure);
  if position('post_events' in d) = 0 then
    d := replace(d, $x$    post_threads = coalesce((p->>'post_threads')::boolean, post_threads),$x$, $x$    post_threads = coalesce((p->>'post_threads')::boolean, post_threads),
    post_events = coalesce((p->>'post_events')::boolean, post_events),
    dm_interested = coalesce((p->>'dm_interested')::boolean, dm_interested),$x$);
    execute d;
  end if;
end $$;
