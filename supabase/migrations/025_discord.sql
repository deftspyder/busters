-- Discord posts: Busters posts into a crew's Discord channel through a webhook.
-- The webhook link is a secret: it lives only in this table, is never returned to the app,
-- and only crew admins can set it.
create table if not exists public.crew_discord (
  crew_id uuid primary key references public.crews(id) on delete cascade,
  webhook_url text,
  post_short boolean not null default true,     -- short-staffed nudges
  short_days int not null default 3 check (short_days between 1 and 14),
  post_photos boolean not null default true,    -- "drop your photos" after an event
  updated_at timestamptz not null default now()
);
alter table public.crew_discord enable row level security;

create table if not exists public.discord_log (
  id bigserial primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  kind text not null,              -- short, photos, manual, test
  event_id uuid references public.events(id) on delete cascade,
  status int,
  at timestamptz not null default now()
);
create unique index if not exists discord_log_once on public.discord_log (kind, event_id) where kind in ('short', 'photos');
alter table public.discord_log enable row level security;

-- Sends one message. Internal only. Mentions are switched off so a post can never ping @everyone.
create or replace function public.discord_send(p_crew uuid, p_text text) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare u text; r record;
begin
  select webhook_url into u from public.crew_discord where crew_id = p_crew;
  if u is null then return null; end if;
  select status into r from extensions.http_post(u,
    json_build_object('username', 'Busters', 'content', left(p_text, 1900),
                      'allowed_mentions', json_build_object('parse', json_build_array()))::text,
    'application/json');
  return r.status;
exception when others then return -1;
end $$;
revoke all on function public.discord_send(uuid, text) from public, anon, authenticated;

create or replace function public.event_link(p_event uuid) returns text
language sql immutable set search_path = '' as $$
  select 'https://deftspyder.github.io/busters/#event/' || p_event::text;
$$;

-- What the Team tab shows: whether a webhook is set (only its last 4 characters), and the switches.
create or replace function public.discord_settings(p_crew uuid) returns json
language sql stable security definer set search_path = '' as $$
  select case when public.can(p_crew, 'crew_admin') then (
    select json_build_object('has_hook', d.webhook_url is not null, 'tail', right(d.webhook_url, 4),
      'post_short', coalesce(d.post_short, true), 'short_days', coalesce(d.short_days, 3), 'post_photos', coalesce(d.post_photos, true),
      'last', (select json_build_object('kind', l.kind, 'status', l.status, 'at', l.at) from public.discord_log l
               where l.crew_id = p_crew order by l.at desc limit 1))
    from (select p_crew as c) x left join public.crew_discord d on d.crew_id = x.c) end;
$$;

-- p_url: null keeps the current link, '' removes it.
create or replace function public.set_discord(p_crew uuid, p_url text, p_short boolean, p_days int, p_photos boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  if p_url is not null and p_url <> '' and p_url !~ '^https://(discord|discordapp|canary\.discord|ptb\.discord)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$' then
    raise exception 'That does not look like a Discord webhook link';
  end if;
  insert into public.crew_discord (crew_id, webhook_url, post_short, short_days, post_photos)
  values (p_crew, nullif(p_url, ''), coalesce(p_short, true), coalesce(p_days, 3), coalesce(p_photos, true))
  on conflict (crew_id) do update set
    webhook_url = case when p_url is null then public.crew_discord.webhook_url else nullif(p_url, '') end,
    post_short = coalesce(p_short, public.crew_discord.post_short),
    short_days = coalesce(p_days, public.crew_discord.short_days),
    post_photos = coalesce(p_photos, public.crew_discord.post_photos),
    updated_at = now();
  perform public.log_action(p_crew, 'discord_settings', 'crew', p_crew,
    case when p_url = '' then 'Removed the Discord webhook' when p_url is not null then 'Set the Discord webhook' else 'Changed Discord post settings' end);
end $$;

create or replace function public.discord_test(p_crew uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare st int;
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  st := public.discord_send(p_crew, 'Busters is connected to this channel. Event nudges and photo calls will show up here.');
  insert into public.discord_log (crew_id, kind, status) values (p_crew, 'test', st);
  return st;
end $$;

-- Editors can post an event to Discord by hand, with an optional line of their own.
create or replace function public.discord_post_event(p_event uuid, p_note text) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events_full; st int; txt text;
begin
  select * into e from public.events_full where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  if not public.can(e.crew_id, 'edit_events') then raise exception 'not allowed'; end if;
  txt := coalesce(nullif(trim(p_note), '') || E'\n', '')
    || '**' || e.title || '**, ' || to_char(e.event_date, 'FMDay, Mon FMDD')
    || coalesce(' at ' || to_char(coalesce(e.call_time, e.start_time), 'FMHH12:MI AM'), '')
    || E'\n' || e.going || coalesce(' of ' || e.min_busters, '') || ' Busters going. Sign up: ' || public.event_link(e.id);
  st := public.discord_send(e.crew_id, txt);
  insert into public.discord_log (crew_id, kind, event_id, status) values (e.crew_id, 'manual', e.id, st);
  perform public.log_action(e.crew_id, 'discord_post', 'event', e.id, 'Posted ' || e.title || ' to Discord');
  return st;
end $$;

-- Runs every 15 minutes: short-staffed nudges, and a photo call the morning after an event.
create or replace function public.discord_run() returns text
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
  hr int := extract(hour from now() at time zone 'America/Los_Angeles');
begin
  if hr < 9 or hr >= 21 then return 'quiet hours'; end if;
  -- short-staffed
  for r in
    select e.*, d.short_days from public.events_full e join public.crew_discord d on d.crew_id = e.crew_id
    where d.webhook_url is not null and d.post_short and e.status = 'scheduled'
      and e.min_busters is not null and e.going < e.min_busters
      and e.event_date between today and today + d.short_days
      and not exists (select 1 from public.discord_log l where l.kind = 'short' and l.event_id = e.id)
  loop
    st := public.discord_send(r.crew_id,
      ':rotating_light: **' || r.title || '** on ' || to_char(r.event_date, 'FMDay, Mon FMDD')
      || ' needs ' || (r.min_busters - r.going) || ' more ' || case when r.min_busters - r.going = 1 then 'Buster' else 'Busters' end
      || ' (' || r.going || ' of ' || r.min_busters || ' so far). Can you make it? ' || public.event_link(r.id));
    insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'short', r.id, st);
    n := n + 1;
  end loop;
  -- photo call, the day after (or two) an event ends
  for r in
    select e.* from public.events e join public.crew_discord d on d.crew_id = e.crew_id
    where d.webhook_url is not null and d.post_photos and e.status in ('scheduled', 'closed')
      and coalesce(e.end_date, e.event_date) between today - 2 and today - 1
      and not exists (select 1 from public.discord_log l where l.kind = 'photos' and l.event_id = e.id)
  loop
    st := public.discord_send(r.crew_id,
      ':camera: Were you at **' || r.title || '**? Reply here with your photos and videos.'
      || coalesce(E'\nThanks to ' || (select string_agg(coalesce(p.callsign, split_part(p.full_name, ' ', 1)), ', ' order by p.full_name)
           from public.event_workers(r.id) w join public.people p on p.id = w) || ' for busting at this one!', ''));
    insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'photos', r.id, st);
    n := n + 1;
  end loop;
  return 'posted ' || n;
end $$;

revoke all on function public.discord_run() from public, anon, authenticated;
revoke all on function public.discord_settings(uuid), public.set_discord(uuid, text, boolean, int, boolean),
  public.discord_test(uuid), public.discord_post_event(uuid, text) from public, anon;
grant execute on function public.discord_settings(uuid), public.set_discord(uuid, text, boolean, int, boolean),
  public.discord_test(uuid), public.discord_post_event(uuid, text) to authenticated;

select cron.schedule('discord-run', '2,17,32,47 * * * *', 'select public.discord_run()');
