-- Discord: post what changed on an upcoming event (times added or moved, new date, places, parking, cancelled).
-- Changes are collected as they happen (app edits, calendar and sheet syncs) and posted once they settle
-- for 10 minutes, as one message per event. A change that's undone before posting isn't posted.
alter table public.crew_discord add column if not exists post_changes boolean not null default true;

create table if not exists public.discord_changes (
  id bigserial primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  field text not null,          -- call_time, start_time, wrap_time, event_date, end_date, title, parking, status, place:<label>
  old_val text,
  new_val text,
  at timestamptz not null default now(),
  posted_at timestamptz
);
create unique index if not exists discord_changes_open on public.discord_changes (event_id, field) where posted_at is null;
alter table public.discord_changes enable row level security;

create or replace function public.dc_note(p_crew uuid, p_event uuid, p_field text, p_old text, p_new text)
returns void language sql security definer set search_path = '' as $$
  insert into public.discord_changes (crew_id, event_id, field, old_val, new_val)
  values (p_crew, p_event, p_field, p_old, p_new)
  on conflict (event_id, field) where posted_at is null
  do update set new_val = excluded.new_val, at = now();
$$;

create or replace function public.dc_time(t time) returns text language sql immutable set search_path = '' as $$
  select to_char(t, 'FMHH12:MI AM');
$$;
create or replace function public.dc_day(d date) returns text language sql immutable set search_path = '' as $$
  select to_char(d, 'FMDy, Mon FMDD');
$$;

create or replace function public.dc_events_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if new.created_at > now() - interval '10 minutes' then return new; end if;   -- still being set up
  if greatest(old.event_date, new.event_date) < today then return new; end if;  -- past events
  if new.status = 'proposed' then return new; end if;
  if new.status is distinct from old.status and (new.status = 'cancelled' or old.status = 'cancelled') then
    perform public.dc_note(new.crew_id, new.id, 'status', old.status, new.status);
  end if;
  if new.status <> 'scheduled' then return new; end if;
  if new.title is distinct from old.title then perform public.dc_note(new.crew_id, new.id, 'title', old.title, new.title); end if;
  if new.event_date is distinct from old.event_date then perform public.dc_note(new.crew_id, new.id, 'event_date', public.dc_day(old.event_date), public.dc_day(new.event_date)); end if;
  if new.end_date is distinct from old.end_date then perform public.dc_note(new.crew_id, new.id, 'end_date', public.dc_day(old.end_date), public.dc_day(new.end_date)); end if;
  if new.call_time is distinct from old.call_time then perform public.dc_note(new.crew_id, new.id, 'call_time', public.dc_time(old.call_time), public.dc_time(new.call_time)); end if;
  if new.start_time is distinct from old.start_time then perform public.dc_note(new.crew_id, new.id, 'start_time', public.dc_time(old.start_time), public.dc_time(new.start_time)); end if;
  if new.wrap_time is distinct from old.wrap_time then perform public.dc_note(new.crew_id, new.id, 'wrap_time', public.dc_time(old.wrap_time), public.dc_time(new.wrap_time)); end if;
  if nullif(trim(new.parking), '') is distinct from nullif(trim(old.parking), '') then
    perform public.dc_note(new.crew_id, new.id, 'parking', nullif(trim(old.parking), ''), nullif(trim(new.parking), ''));
  end if;
  return new;
end $$;
drop trigger if exists dc_events_changed on public.events;
create trigger dc_events_changed after update on public.events for each row execute function public.dc_events_changed();

create or replace function public.dc_places_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r public.event_places; e public.events; pl text;
  today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  select * into e from public.events where id = r.event_id;
  if e.id is null or e.status <> 'scheduled' or e.event_date < today or e.created_at > now() - interval '10 minutes' then return null; end if;
  select p.name || coalesce(', ' || p.address, '') into pl from public.places p where p.id = r.place_id;
  if tg_op = 'DELETE' then
    insert into public.discord_changes (crew_id, event_id, field, old_val, new_val)
    values (e.crew_id, e.id, 'place:' || coalesce(old.label, 'Event'), pl, null)
    on conflict (event_id, field) where posted_at is null do update set new_val = null, at = now();
  else
    insert into public.discord_changes (crew_id, event_id, field, old_val, new_val)
    values (e.crew_id, e.id, 'place:' || coalesce(new.label, 'Event'), null, pl)
    on conflict (event_id, field) where posted_at is null do update set new_val = excluded.new_val, at = now();
  end if;
  return null;
end $$;
drop trigger if exists dc_places_changed on public.event_places;
create trigger dc_places_changed after insert or delete on public.event_places for each row execute function public.dc_places_changed();

revoke all on function public.dc_note(uuid, uuid, text, text, text), public.dc_events_changed(), public.dc_places_changed() from public, anon, authenticated;

-- One line per change, in a sensible order.
create or replace function public.dc_change_lines(p_event uuid) returns text
language sql stable security definer set search_path = '' as $$
  select string_agg('• ' || case
      when c.field in ('call_time', 'start_time', 'wrap_time', 'event_date', 'end_date') then
        (case c.field when 'call_time' then 'Call time' when 'start_time' then 'Start time' when 'wrap_time' then 'Wrap time'
                      when 'event_date' then 'Date' else 'Last day' end)
        || case when c.old_val is null then ' added: **' || c.new_val || '**'
                when c.new_val is null then ' removed (was ' || c.old_val || ')'
                else ' moved from ' || c.old_val || ' to **' || c.new_val || '**' end
      when c.field = 'title' then 'Renamed from "' || c.old_val || '"'
      when c.field = 'parking' then case when c.old_val is null then 'Parking info added' else 'Parking info updated' end
      when c.field like 'place:%' then
        substr(c.field, 7) || case when c.new_val is null then ' removed' when c.old_val is null then ': **' || c.new_val || '**'
                                   else ' changed to **' || c.new_val || '**' end
    end, E'\n' order by array_position(array['event_date','end_date','call_time','start_time','wrap_time','title'], c.field) nulls last, c.field)
  from public.discord_changes c
  where c.event_id = p_event and c.posted_at is null and c.field <> 'status'
    and c.old_val is distinct from c.new_val;
$$;
revoke all on function public.dc_change_lines(uuid) from public, anon, authenticated;

create or replace function public.discord_settings(p_crew uuid) returns json
language sql stable security definer set search_path = '' as $$
  select case when public.can(p_crew, 'crew_admin') then (
    select json_build_object('has_hook', d.webhook_url is not null, 'tail', right(d.webhook_url, 4),
      'has_bot', d.bot_token is not null, 'app_id', d.app_id, 'channel_id', d.channel_id, 'bot_name', d.bot_name, 'channel_name', d.channel_name, 'checked', d.bot_checked_at,
      'post_short', coalesce(d.post_short, true), 'short_days', coalesce(d.short_days, 3), 'post_photos', coalesce(d.post_photos, true),
      'post_changes', coalesce(d.post_changes, true),
      'last', (select json_build_object('kind', l.kind, 'status', l.status, 'at', l.at) from public.discord_log l
               where l.crew_id = p_crew order by l.at desc limit 1))
    from (select p_crew as c) x left join public.crew_discord d on d.crew_id = x.c) end;
$$;

create or replace function public.set_discord_changes(p_crew uuid, p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  insert into public.crew_discord (crew_id, post_changes) values (p_crew, p_on)
  on conflict (crew_id) do update set post_changes = p_on, updated_at = now();
end $$;
revoke all on function public.set_discord_changes(uuid, boolean) from public, anon;
grant execute on function public.set_discord_changes(uuid, boolean) to authenticated;

-- Post settled changes. Called from discord_run.
create or replace function public.discord_post_changes() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; lines text; txt text; cancelled text;
begin
  for r in
    select e.*, max(c.at) as last_at from public.discord_changes c
    join public.events e on e.id = c.event_id
    join public.crew_discord d on d.crew_id = e.crew_id
    where c.posted_at is null and d.post_changes and d.bot_token is not null and d.channel_id is not null
    group by e.id having max(c.at) < now() - interval '10 minutes'
  loop
    select new_val into cancelled from public.discord_changes where event_id = r.id and field = 'status' and posted_at is null and old_val is distinct from new_val;
    lines := public.dc_change_lines(r.id);
    if cancelled = 'cancelled' and r.status = 'cancelled' then
      txt := ':x: **' || r.title || '** on ' || public.dc_day(r.event_date) || ' is **cancelled**.';
    elsif cancelled = 'scheduled' and r.status = 'scheduled' then
      txt := ':white_check_mark: **' || r.title || '** on ' || public.dc_day(r.event_date) || ' is back on!'
        || coalesce(E'\n' || lines, '');
    elsif lines is not null and r.status = 'scheduled' then
      txt := ':pencil: **' || r.title || '** (' || public.dc_day(r.event_date) || ') was updated:' || E'\n' || lines;
    else
      txt := null;
    end if;
    if txt is not null then
      st := public.discord_send(r.crew_id, txt);
      insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'changes', r.id, st);
      n := n + 1;
    end if;
    update public.discord_changes set posted_at = now() where event_id = r.id and posted_at is null;
  end loop;
  return n;
end $$;
revoke all on function public.discord_post_changes() from public, anon, authenticated;

-- No app links in Discord posts while Busters isn't open to everyone yet.
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
    || E'\n' || e.going || coalesce(' of ' || e.min_busters, '') || ' Busters going.';
  st := public.discord_send(e.crew_id, txt);
  insert into public.discord_log (crew_id, kind, event_id, status) values (e.crew_id, 'manual', e.id, st);
  perform public.log_action(e.crew_id, 'discord_post', 'event', e.id, 'Posted ' || e.title || ' to Discord');
  return st;
end $$;

create or replace function public.discord_run() returns text
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
  hr int := extract(hour from now() at time zone 'America/Los_Angeles');
begin
  if hr < 9 or hr >= 21 then return 'quiet hours'; end if;
  n := public.discord_post_changes();
  for r in
    select e.*, d.short_days from public.events_full e join public.crew_discord d on d.crew_id = e.crew_id
    where (d.webhook_url is not null or (d.bot_token is not null and d.channel_id is not null)) and d.post_short and e.status = 'scheduled'
      and e.min_busters is not null and e.going < e.min_busters
      and e.event_date between today and today + d.short_days
      and not exists (select 1 from public.discord_log l where l.kind = 'short' and l.event_id = e.id)
  loop
    st := public.discord_send(r.crew_id,
      ':rotating_light: **' || r.title || '** on ' || to_char(r.event_date, 'FMDay, Mon FMDD')
      || ' needs ' || (r.min_busters - r.going) || ' more ' || case when r.min_busters - r.going = 1 then 'Buster' else 'Busters' end
      || ' (' || r.going || ' of ' || r.min_busters || ' so far). Can you make it?');
    insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'short', r.id, st);
    n := n + 1;
  end loop;
  for r in
    select e.* from public.events e join public.crew_discord d on d.crew_id = e.crew_id
    where (d.webhook_url is not null or (d.bot_token is not null and d.channel_id is not null)) and d.post_photos and e.status in ('scheduled', 'closed')
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
