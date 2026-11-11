-- Discord posting schedule for the events team, with bumping.
-- Each upcoming event has at most ONE card in the channel. Every scheduled post (new event, reminders,
-- last call, short-staffed repeats, what changed, manual posts) is a bump: the bot posts a fresh card at the
-- bottom, then deletes its previous card for that event. Between bumps the card's Busters count is kept current.

alter table public.crew_discord
  add column if not exists post_new boolean not null default true,         -- card when an event is added
  add column if not exists remind_days int[] not null default '{7,3}',     -- reminder bumps, days before
  add column if not exists last_call boolean not null default true,        -- bump 48 hours before
  add column if not exists short_every int not null default 12,            -- hours between short-staffed bumps, 0 = once
  add column if not exists quiet_from int not null default 22,             -- no posts from this hour...
  add column if not exists quiet_to int not null default 8,                -- ...until this hour (LA time)
  add column if not exists max_posts int not null default 8,               -- cap on scheduled posts per event
  add column if not exists schedule_since timestamptz not null default now(); -- only events added after this get a "new" card

alter table public.discord_log
  add column if not exists going_shown int,
  add column if not exists card_kind text,
  add column if not exists card_extra text;

-- Short-staffed posts can now repeat (as bumps); photo calls stay once per event.
drop index if exists public.discord_log_once;
create unique index if not exists discord_log_photos_once on public.discord_log (event_id) where kind = 'photos';

create or replace function public.dc_quiet(p_from int, p_to int) returns boolean
language sql stable set search_path = '' as $$
  select case when p_from = p_to then false
              when p_from > p_to then h >= p_from or h < p_to
              else h >= p_from and h < p_to end
  from (select extract(hour from now() at time zone 'America/Los_Angeles')::int as h) x;
$$;

create or replace function public.dc_http(p_crew uuid, p_method text, p_path text, p_body jsonb) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare d public.crew_discord; r record;
begin
  select * into d from public.crew_discord where crew_id = p_crew;
  if d.bot_token is null then return null; end if;
  select status into r from extensions.http((
    p_method, 'https://discord.com/api/v10' || p_path,
    array[extensions.http_header('Authorization', 'Bot ' || d.bot_token),
          extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
    case when p_body is null then null else 'application/json' end, p_body::text)::extensions.http_request);
  return r.status;
exception when others then return -1;
end $$;
revoke all on function public.dc_http(uuid, text, text, jsonb) from public, anon, authenticated;

-- Card look for each kind of post.
create or replace function public.dc_embed(p_event uuid, p_kind text, p_extra text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.events_full; pl record; f jsonb := '[]'::jsonb; crew text; head text; color int; descr text;
begin
  select * into e from public.events_full where id = p_event;
  select c.short_name into crew from public.crews c where c.id = e.crew_id;
  select p.name, p.address, ep.label into pl from public.event_places ep join public.places p on p.id = ep.place_id
    where ep.event_id = p_event order by (coalesce(ep.label, 'Event') = 'Event') desc, ep.sort limit 1;
  head := case p_kind when 'short' then '🚨 Short on Busters' when 'changes' then '✏️ Event updated'
    when 'cancelled' then '❌ Cancelled' when 'backon' then '✅ Back on' when 'photos' then '📷 Photo call'
    when 'new' then '🆕 New event' when 'remind' then '⏰ Coming up' when 'lastcall' then '📣 Last call' else '📣 Event' end;
  color := case p_kind when 'short' then 15774258 when 'cancelled' then 8421504 when 'backon' then 5763719
    when 'photos' then 3908599 when 'lastcall' then 16753920 when 'remind' then 3447003 else 14957114 end;
  if p_kind = 'photos' then
    descr := 'Were you there? Reply here with your photos and videos.' || coalesce(E'\n\n' || p_extra, '');
  elsif p_kind in ('manual', 'new', 'remind', 'lastcall', 'short') then
    descr := p_extra;
  end if;
  if p_kind <> 'photos' then
    f := f || jsonb_build_object('name', 'Date', 'value',
      public.dc_day(e.event_date) || case when e.end_date is not null and e.end_date <> e.event_date then ' to ' || public.dc_day(e.end_date) else '' end, 'inline', true);
    if e.call_time is not null then f := f || jsonb_build_object('name', 'Call time', 'value', public.dc_time(e.call_time), 'inline', true); end if;
    if e.start_time is not null then f := f || jsonb_build_object('name', 'Start', 'value',
      public.dc_time(e.start_time) || coalesce(' to ' || public.dc_time(e.wrap_time), ''), 'inline', true); end if;
    if e.call_time is null and e.start_time is null then f := f || jsonb_build_object('name', 'Time', 'value', 'Coming soon', 'inline', true); end if;
    if pl.name is not null then f := f || jsonb_build_object('name', case when coalesce(pl.label, 'Event') = 'Event' then 'Location' else pl.label end, 'value', pl.name || coalesce(E'\n' || pl.address, ''), 'inline', false); end if;
    if p_kind <> 'cancelled' then f := f || jsonb_build_object('name', 'Busters', 'value', public.dc_count(e.going, e.min_busters), 'inline', false); end if;
    if p_kind in ('changes', 'backon') and p_extra is not null then f := f || jsonb_build_object('name', 'What changed', 'value', left(p_extra, 1000), 'inline', false); end if;
  end if;
  return jsonb_strip_nulls(jsonb_build_object('color', color, 'author', jsonb_build_object('name', head),
    'title', left(e.title, 250), 'description', descr, 'fields', f,
    'footer', jsonb_build_object('text', coalesce(crew, '') || ' · Busters')));
end $$;

-- Post a fresh card for an event, then remove the bot's older card(s) for it. Returns Discord's status.
create or replace function public.dc_bump(p_event uuid, p_reason text, p_kind text, p_extra text) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events; g int; st int; nid bigint; r record; ds int;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then return null; end if;
  select going into g from public.events_full where id = p_event;
  st := public.dc_send_event(p_event, p_kind, p_extra);
  insert into public.discord_log (crew_id, kind, event_id, status, going_shown, card_kind, card_extra)
  values (e.crew_id, p_reason, p_event, st, g, p_kind, p_extra) returning id into nid;
  if st between 200 and 299 then
    for r in select l.id, l.channel_id, l.message_id from public.discord_log l
      where l.event_id = p_event and l.id <> nid and l.message_id is not null and l.deleted_at is null
        and l.kind not in ('photos', 'test')
    loop
      ds := public.dc_http(e.crew_id, 'DELETE', '/channels/' || r.channel_id || '/messages/' || r.message_id, null);
      if ds in (200, 204, 404) then update public.discord_log set deleted_at = now() where id = r.id; end if;
    end loop;
  end if;
  return st;
end $$;
revoke all on function public.dc_bump(uuid, text, text, text) from public, anon, authenticated;

-- When an event's next scheduled post is due, and why. Used by the runner and shown to the events team.
create or replace function public.dc_next(p_event uuid)
returns table (reason text, label text, due_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare e public.events_full; d public.crew_discord; tz text := 'America/Los_Angeles';
  start_ts timestamptz; last_at timestamptz; autos int; at timestamptz; n int; h int;
  b_at timestamptz; b_reason text; b_label text; b_pri int := 99; short_now boolean;
begin
  select * into e from public.events_full where id = p_event;
  if e.id is null or e.status <> 'scheduled' then return; end if;
  select * into d from public.crew_discord where crew_id = e.crew_id;
  if d.bot_token is null or d.channel_id is null then return; end if;
  start_ts := ((e.event_date + coalesce(e.call_time, e.start_time, time '09:00'))::timestamp at time zone tz);
  if start_ts <= now() then return; end if;
  select max(l.at) filter (where l.status between 200 and 299),
         count(*) filter (where l.status between 200 and 299 and (l.kind in ('new', 'lastcall', 'short') or l.kind like 'remind%'))
    into last_at, autos
  from public.discord_log l where l.event_id = e.id and l.kind not in ('photos', 'test');
  if autos >= d.max_posts then return; end if;

  -- new event card
  if d.post_new and last_at is null and e.created_at > d.schedule_since then
    at := e.created_at + interval '10 minutes';
    if at < b_at or b_at is null or (at = b_at and 4 < b_pri) then b_at := at; b_reason := 'new'; b_label := 'New event post'; b_pri := 4; end if;
  end if;
  -- last call, 48 hours before
  if d.last_call and not exists (select 1 from public.discord_log l where l.event_id = e.id and l.kind = 'lastcall' and l.status between 200 and 299) then
    at := greatest(start_ts - interval '48 hours', coalesce(last_at + interval '12 hours', start_ts - interval '48 hours'));
    if at < start_ts and (b_at is null or at < b_at or (at = b_at and 1 < b_pri)) then b_at := at; b_reason := 'lastcall'; b_label := 'Last call, 48 hours before'; b_pri := 1; end if;
  end if;
  -- reminders, N days before (10 am)
  if not exists (select 1 from public.discord_log l where l.event_id = e.id and l.kind = 'lastcall' and l.status between 200 and 299) then
    foreach n in array d.remind_days loop
      continue when d.last_call and n <= 2;
      continue when exists (select 1 from public.discord_log l where l.event_id = e.id and l.kind = 'remind' || n and l.status between 200 and 299);
      at := ((e.event_date - n) + time '10:00')::timestamp at time zone tz;
      continue when at < e.created_at or at < now() - interval '1 day';
      at := greatest(at, coalesce(last_at + interval '12 hours', at));
      if at < start_ts and (b_at is null or at < b_at or (at = b_at and 2 < b_pri)) then
        b_at := at; b_reason := 'remind' || n; b_pri := 2;
        b_label := 'Reminder, ' || case n when 1 then '1 day' when 7 then '1 week' when 14 then '2 weeks' else n || ' days' end || ' before';
      end if;
    end loop;
  end if;
  -- short-staffed: first post N days out, then a bump every few hours while still short
  short_now := d.post_short and e.min_busters is not null and e.going < e.min_busters;
  if short_now then
    if not exists (select 1 from public.discord_log l where l.event_id = e.id and l.kind = 'short' and l.status between 200 and 299) then
      at := greatest(((e.event_date - d.short_days) + time '10:00')::timestamp at time zone tz, e.created_at + interval '10 minutes');
    elsif d.short_every > 0 then
      at := last_at + make_interval(hours => d.short_every);
    else at := null; end if;
    if at is not null and at < start_ts and (b_at is null or at < b_at or (at = b_at and 3 < b_pri)) then
      b_at := at; b_reason := 'short'; b_pri := 3;
      b_label := case when exists (select 1 from public.discord_log l where l.event_id = e.id and l.kind = 'short') then 'Short-staffed bump' else 'Short-staffed post' end;
    end if;
  end if;

  if b_at is null then return; end if;
  if last_at is not null then b_at := greatest(b_at, last_at + interval '1 hour'); end if;
  -- push out of quiet hours
  h := extract(hour from b_at at time zone tz)::int;
  if d.quiet_from <> d.quiet_to and ((d.quiet_from > d.quiet_to and (h >= d.quiet_from or h < d.quiet_to)) or (d.quiet_from < d.quiet_to and h >= d.quiet_from and h < d.quiet_to)) then
    b_at := ((((b_at at time zone tz)::date + case when d.quiet_from > d.quiet_to and h >= d.quiet_from then 1 else 0 end)
              + make_time(d.quiet_to, 0, 0))::timestamp at time zone tz);
  end if;
  if b_at >= start_ts then return; end if;
  reason := b_reason; label := b_label; due_at := b_at; return next;
end $$;
revoke all on function public.dc_next(uuid) from public, anon, authenticated;

-- What changed, cancelled and back on now bump the event's card too.
create or replace function public.discord_post_changes() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; lines text; kind text; cancelled text;
begin
  for r in
    select e.id, e.crew_id, e.status from public.discord_changes c
    join public.events e on e.id = c.event_id
    join public.crew_discord d on d.crew_id = e.crew_id
    where c.posted_at is null and d.post_changes and d.bot_token is not null and d.channel_id is not null
      and not public.dc_quiet(d.quiet_from, d.quiet_to)
    group by e.id having max(c.at) < now() - interval '10 minutes'
  loop
    cancelled := null;
    select new_val into cancelled from public.discord_changes where event_id = r.id and field = 'status' and posted_at is null and old_val is distinct from new_val;
    lines := public.dc_change_lines(r.id);
    kind := case when cancelled = 'cancelled' and r.status = 'cancelled' then 'cancelled'
                 when cancelled = 'scheduled' and r.status = 'scheduled' then 'backon'
                 when lines is not null and r.status = 'scheduled' then 'changes' end;
    if kind is not null then
      st := public.dc_bump(r.id, 'changes', kind, lines);
      n := n + 1;
    end if;
    update public.discord_changes set posted_at = now() where event_id = r.id and posted_at is null;
  end loop;
  return n;
end $$;

-- Editors posting an event by hand also bump its card.
create or replace function public.discord_post_event(p_event uuid, p_note text) returns integer
language plpgsql security definer set search_path = '' as $$
declare e public.events; st int;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  if not public.can(e.crew_id, 'edit_events') then raise exception 'not allowed'; end if;
  st := public.dc_bump(e.id, 'manual', 'manual', nullif(trim(left(p_note, 300)), ''));
  perform public.log_action(e.crew_id, 'discord_post', 'event', e.id, 'Posted ' || e.title || ' to Discord');
  return st;
end $$;

-- Every 15 minutes.
create or replace function public.discord_run() returns text
language plpgsql security definer set search_path = '' as $$
declare d record; r record; nx record; st int; n int := 0; per int; today date := (now() at time zone 'America/Los_Angeles')::date;
  thanks text; ex text; k text;
begin
  n := public.discord_post_changes();
  for d in select * from public.crew_discord where bot_token is not null and channel_id is not null loop
    -- keep live cards' Busters counts current (edits are silent, so these run in quiet hours too)
    for r in
      select l.id, l.channel_id, l.message_id, l.event_id, l.card_kind, l.card_extra, ef.going
      from public.discord_log l join public.events_full ef on ef.id = l.event_id
      where l.crew_id = d.crew_id and l.message_id is not null and l.deleted_at is null and l.card_kind is not null
        and l.kind not in ('photos', 'test') and ef.going is distinct from l.going_shown and ef.event_date >= today
    loop
      st := public.dc_http(d.crew_id, 'PATCH', '/channels/' || r.channel_id || '/messages/' || r.message_id,
        jsonb_build_object('embeds', jsonb_build_array(public.dc_embed(r.event_id, r.card_kind, r.card_extra))));
      if st between 200 and 299 then update public.discord_log set going_shown = r.going where id = r.id;
      elsif st = 404 then update public.discord_log set deleted_at = now() where id = r.id; end if;
    end loop;

    continue when public.dc_quiet(d.quiet_from, d.quiet_to);
    per := 0;
    for r in select e.id from public.events e where e.crew_id = d.crew_id and e.status = 'scheduled'
               and e.event_date between today and today + 60 order by e.event_date loop
      exit when per >= 5;                                     -- never more than 5 posts per run
      select * into nx from public.dc_next(r.id);
      continue when nx.due_at is null or nx.due_at > now();
      k := case when nx.reason like 'remind%' then 'remind' else nx.reason end;
      ex := case
        when nx.reason = 'lastcall' then 'Starts within 48 hours. Last chance to sign up!'
        when nx.reason = 'remind7' then 'One week out.'
        when nx.reason = 'remind14' then 'Two weeks out.'
        when nx.reason = 'remind1' then 'Tomorrow!'
        when nx.reason like 'remind%' then 'In ' || substr(nx.reason, 7) || ' days.'
        when nx.reason = 'short' then 'We could use a few more for this one. Can you make it?'
        end;
      st := public.dc_bump(r.id, nx.reason, k, ex);
      per := per + 1; n := n + 1;
    end loop;

    -- photo call, the day after (or two) an event ends (still off until Jeff's Dropbox drop)
    for r in
      select e.id, e.crew_id from public.events e
      where e.crew_id = d.crew_id and d.post_photos and e.status in ('scheduled', 'closed')
        and coalesce(e.end_date, e.event_date) between today - 2 and today - 1
        and not exists (select 1 from public.discord_log l where l.kind = 'photos' and l.event_id = e.id)
    loop
      select 'Thanks to ' || string_agg(coalesce(p.callsign, split_part(p.full_name, ' ', 1)), ', ' order by p.full_name) || ' for busting at this one!'
        into thanks from public.event_workers(r.id) w join public.people p on p.id = w;
      st := public.dc_send_event(r.id, 'photos', thanks);
      insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'photos', r.id, st);
      n := n + 1;
    end loop;
  end loop;
  return 'posted ' || n;
end $$;
revoke all on function public.discord_run() from public, anon, authenticated;

-- The events team's schedule page: settings plus what's coming up next for each event.
create or replace function public.discord_schedule(p_crew uuid) returns json
language plpgsql stable security definer set search_path = '' as $$
declare d public.crew_discord; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if not public.can(p_crew, 'edit_events') then raise exception 'not allowed'; end if;
  select * into d from public.crew_discord where crew_id = p_crew;
  return json_build_object(
    'connected', d.bot_token is not null and d.channel_id is not null, 'channel', d.channel_name,
    'post_new', coalesce(d.post_new, true), 'remind_days', coalesce(d.remind_days, '{7,3}'), 'last_call', coalesce(d.last_call, true),
    'post_short', coalesce(d.post_short, true), 'short_days', coalesce(d.short_days, 3), 'short_every', coalesce(d.short_every, 12),
    'quiet_from', coalesce(d.quiet_from, 22), 'quiet_to', coalesce(d.quiet_to, 8), 'max_posts', coalesce(d.max_posts, 8),
    'upcoming', (select coalesce(json_agg(x order by x.due_at nulls last, x.event_date), '[]') from (
      select e.id, e.title, e.event_date, nx.label, nx.due_at,
        (select max(l.at) from public.discord_log l where l.event_id = e.id and l.message_id is not null and l.deleted_at is null and l.kind not in ('photos', 'test')) as card_at
      from public.events e left join lateral public.dc_next(e.id) nx on true
      where e.crew_id = p_crew and e.status = 'scheduled' and e.event_date between today and today + 45) x));
end $$;

create or replace function public.set_discord_schedule(p_crew uuid, p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare days int[];
begin
  if not public.can(p_crew, 'edit_events') then raise exception 'not allowed'; end if;
  select coalesce(array_agg(distinct v::int order by v::int desc), '{}') into days
    from jsonb_array_elements_text(coalesce(p->'remind_days', '[]'::jsonb)) v where v ~ '^[0-9]+$' and v::int between 1 and 30;
  insert into public.crew_discord (crew_id) values (p_crew) on conflict (crew_id) do nothing;
  update public.crew_discord set
    post_new = coalesce((p->>'post_new')::boolean, post_new),
    remind_days = case when p ? 'remind_days' then days else remind_days end,
    last_call = coalesce((p->>'last_call')::boolean, last_call),
    post_short = coalesce((p->>'post_short')::boolean, post_short),
    short_days = least(14, greatest(1, coalesce((p->>'short_days')::int, short_days))),
    short_every = least(48, greatest(0, coalesce((p->>'short_every')::int, short_every))),
    quiet_from = least(23, greatest(0, coalesce((p->>'quiet_from')::int, quiet_from))),
    quiet_to = least(23, greatest(0, coalesce((p->>'quiet_to')::int, quiet_to))),
    max_posts = least(20, greatest(1, coalesce((p->>'max_posts')::int, max_posts))),
    updated_at = now()
  where crew_id = p_crew;
  perform public.log_action(p_crew, 'discord_schedule', 'crew', p_crew, 'Changed the Discord posting schedule');
end $$;

revoke all on function public.discord_schedule(uuid), public.set_discord_schedule(uuid, jsonb) from public, anon;
grant execute on function public.discord_schedule(uuid), public.set_discord_schedule(uuid, jsonb) to authenticated;
