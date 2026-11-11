-- Discord cards (embeds) with Going / Maybe / Can't buttons.
-- Members are matched to their Discord account the first time they tap a button: by a saved link, or by the
-- Discord name in their Busters details. Anyone who can't be matched is listed on the Team tab for an admin to link,
-- and their answer is applied once they're linked.
alter table public.people_private add column if not exists discord_user_id text;
create unique index if not exists people_private_discord_user on public.people_private (crew_id, discord_user_id) where discord_user_id is not null;
alter table public.crew_discord add column if not exists public_key text;
-- Photo calls stay off until Jeff's Dropbox drop is hooked up.
alter table public.crew_discord alter column post_photos set default false;

create table if not exists public.discord_unlinked (
  crew_id uuid not null references public.crews(id) on delete cascade,
  discord_user_id text not null,
  username text, display_name text,
  pending_event uuid references public.events(id) on delete set null,
  pending_answer text,
  last_at timestamptz not null default now(),
  primary key (crew_id, discord_user_id)
);
alter table public.discord_unlinked enable row level security;

-- Sends any message payload (content, embeds, components). Internal only.
create or replace function public.discord_send_payload(p_crew uuid, p jsonb, p_preview text) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare d public.crew_discord; r record; body jsonb;
begin
  perform set_config('busters.dc_msg', '', true);
  perform set_config('busters.dc_text', left(coalesce(p_preview, p->>'content', ''), 200), true);
  select * into d from public.crew_discord where crew_id = p_crew;
  if d.crew_id is null then return null; end if;
  body := p || jsonb_build_object('allowed_mentions', jsonb_build_object('parse', jsonb_build_array()));
  if d.bot_token is not null and d.channel_id is not null then
    select status, content into r from extensions.http((
      'POST', 'https://discord.com/api/v10/channels/' || d.channel_id || '/messages',
      array[extensions.http_header('Authorization', 'Bot ' || d.bot_token),
            extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
      'application/json', body::text)::extensions.http_request);
    if r.status between 200 and 299 then
      perform set_config('busters.dc_msg', coalesce(r.content::jsonb->>'id', '') || ':' || d.channel_id, true);
    end if;
    return r.status;
  elsif d.webhook_url is not null then
    select status into r from extensions.http_post(d.webhook_url,
      ((body - 'components') || '{"username":"Busters"}'::jsonb)::text, 'application/json');
    return r.status;
  end if;
  return null;
exception when others then return -1;
end $$;

drop function if exists public.discord_send(uuid, text);
create function public.discord_send(p_crew uuid, p_text text) returns int
language sql security definer set search_path = '' as $$
  select public.discord_send_payload(p_crew, jsonb_build_object('content', left(p_text, 1900)), p_text);
$$;
revoke all on function public.discord_send_payload(uuid, jsonb, text), public.discord_send(uuid, text) from public, anon, authenticated;

-- "5 of 8 going, need 3" style count.
create or replace function public.dc_count(p_going int, p_min int) returns text language sql immutable set search_path = '' as $$
  select p_going || coalesce(' of ' || p_min, '') || ' going'
      || case when p_min is not null and p_going < p_min then ', need ' || (p_min - p_going) else '' end;
$$;

-- The card for an event. p_kind: short, changes, cancelled, backon, manual, photos.
create or replace function public.dc_embed(p_event uuid, p_kind text, p_extra text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.events_full; pl record; f jsonb := '[]'::jsonb; crew text; head text; color int; descr text;
begin
  select * into e from public.events_full where id = p_event;
  select c.short_name into crew from public.crews c where c.id = e.crew_id;
  select p.name, p.address, ep.label into pl from public.event_places ep join public.places p on p.id = ep.place_id
    where ep.event_id = p_event order by (coalesce(ep.label, 'Event') = 'Event') desc, ep.sort limit 1;
  head := case p_kind when 'short' then '🚨 Short on Busters' when 'changes' then '✏️ Event updated'
    when 'cancelled' then '❌ Cancelled' when 'backon' then '✅ Back on' when 'photos' then '📷 Photo call' else '📣 Event' end;
  color := case p_kind when 'short' then 15774258 when 'cancelled' then 8421504 when 'backon' then 5763719
    when 'photos' then 3908599 else 14957114 end;
  if p_kind = 'photos' then
    descr := 'Were you there? Reply here with your photos and videos.' || coalesce(E'\n\n' || p_extra, '');
  elsif p_kind = 'manual' then
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

create or replace function public.dc_buttons(p_event uuid) returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_array(jsonb_build_object('type', 1, 'components', jsonb_build_array(
    jsonb_build_object('type', 2, 'style', 3, 'label', 'Going', 'emoji', jsonb_build_object('name', '✅'), 'custom_id', 'rsvp:' || p_event || ':going'),
    jsonb_build_object('type', 2, 'style', 2, 'label', 'Maybe', 'custom_id', 'rsvp:' || p_event || ':maybe'),
    jsonb_build_object('type', 2, 'style', 4, 'label', 'Can''t', 'custom_id', 'rsvp:' || p_event || ':no'))));
$$;

-- Sends a card for an event, with answer buttons when it's still open.
create or replace function public.dc_send_event(p_event uuid, p_kind text, p_extra text) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events; p jsonb;
begin
  select * into e from public.events where id = p_event;
  p := jsonb_build_object('embeds', jsonb_build_array(public.dc_embed(p_event, p_kind, p_extra)));
  if e.status = 'scheduled' and p_kind not in ('photos', 'cancelled') and e.event_date >= (now() at time zone 'America/Los_Angeles')::date then
    p := p || jsonb_build_object('components', public.dc_buttons(p_event));
  end if;
  return public.discord_send_payload(e.crew_id, p, e.title);
end $$;
revoke all on function public.dc_count(int, int), public.dc_embed(uuid, text, text), public.dc_send_event(uuid, text, text) from public, anon, authenticated;

-- Change lines, Discord style: Start: ~~5:00 PM~~ → **5:30 PM**
create or replace function public.dc_change_lines(p_event uuid) returns text
language sql stable security definer set search_path = '' as $$
  select string_agg('• ' || case
      when c.field in ('call_time', 'start_time', 'wrap_time', 'event_date', 'end_date') then
        (case c.field when 'call_time' then 'Call time' when 'start_time' then 'Start' when 'wrap_time' then 'Wrap'
                      when 'event_date' then 'Date' else 'Last day' end) || ': '
        || case when c.old_val is null then '**' || c.new_val || '** (new)'
                when c.new_val is null then '~~' || c.old_val || '~~ (removed)'
                else '~~' || c.old_val || '~~ → **' || c.new_val || '**' end
      when c.field = 'title' then 'Renamed from ~~' || c.old_val || '~~'
      when c.field = 'parking' then case when c.old_val is null then 'Parking info added' else 'Parking info updated' end
      when c.field like 'place:%' then
        substr(c.field, 7) || ': ' || case when c.new_val is null then '~~' || c.old_val || '~~ (removed)'
                                          when c.old_val is null then '**' || c.new_val || '** (new)'
                                          else '**' || c.new_val || '**' end
    end, E'\n' order by array_position(array['event_date','end_date','call_time','start_time','wrap_time','title'], c.field) nulls last, c.field)
  from public.discord_changes c
  where c.event_id = p_event and c.posted_at is null and c.field <> 'status'
    and c.old_val is distinct from c.new_val;
$$;
revoke all on function public.dc_change_lines(uuid) from public, anon, authenticated;

create or replace function public.discord_post_changes() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; lines text; kind text; cancelled text;
begin
  for r in
    select e.id, e.crew_id, e.status from public.discord_changes c
    join public.events e on e.id = c.event_id
    join public.crew_discord d on d.crew_id = e.crew_id
    where c.posted_at is null and d.post_changes and d.bot_token is not null and d.channel_id is not null
    group by e.id having max(c.at) < now() - interval '10 minutes'
  loop
    cancelled := null;
    select new_val into cancelled from public.discord_changes where event_id = r.id and field = 'status' and posted_at is null and old_val is distinct from new_val;
    lines := public.dc_change_lines(r.id);
    kind := case when cancelled = 'cancelled' and r.status = 'cancelled' then 'cancelled'
                 when cancelled = 'scheduled' and r.status = 'scheduled' then 'backon'
                 when lines is not null and r.status = 'scheduled' then 'changes' end;
    if kind is not null then
      st := public.dc_send_event(r.id, kind, lines);
      insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'changes', r.id, st);
      n := n + 1;
    end if;
    update public.discord_changes set posted_at = now() where event_id = r.id and posted_at is null;
  end loop;
  return n;
end $$;
revoke all on function public.discord_post_changes() from public, anon, authenticated;

create or replace function public.discord_post_event(p_event uuid, p_note text) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events; st int;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  if not public.can(e.crew_id, 'edit_events') then raise exception 'not allowed'; end if;
  st := public.dc_send_event(e.id, 'manual', nullif(trim(left(p_note, 300)), ''));
  insert into public.discord_log (crew_id, kind, event_id, status) values (e.crew_id, 'manual', e.id, st);
  perform public.log_action(e.crew_id, 'discord_post', 'event', e.id, 'Posted ' || e.title || ' to Discord');
  return st;
end $$;

create or replace function public.discord_test(p_crew uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare st int;
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  st := public.discord_send_payload(p_crew, jsonb_build_object('embeds', jsonb_build_array(jsonb_build_object(
    'color', 14957114, 'author', jsonb_build_object('name', '👻 Busters'),
    'title', 'Busters is connected', 'description', 'Event updates, short-staffed nudges and photo calls will show up in this channel.'))), 'Busters is connected');
  insert into public.discord_log (crew_id, kind, status) values (p_crew, 'test', st);
  return st;
end $$;

create or replace function public.discord_run() returns text
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
  hr int := extract(hour from now() at time zone 'America/Los_Angeles'); thanks text;
begin
  if hr < 9 or hr >= 21 then return 'quiet hours'; end if;
  n := public.discord_post_changes();
  for r in
    select e.id, e.crew_id from public.events_full e join public.crew_discord d on d.crew_id = e.crew_id
    where (d.webhook_url is not null or (d.bot_token is not null and d.channel_id is not null)) and d.post_short and e.status = 'scheduled'
      and e.min_busters is not null and e.going < e.min_busters
      and e.event_date between today and today + d.short_days
      and not exists (select 1 from public.discord_log l where l.kind = 'short' and l.event_id = e.id)
  loop
    st := public.dc_send_event(r.id, 'short', null);
    insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'short', r.id, st);
    n := n + 1;
  end loop;
  for r in
    select e.id, e.crew_id from public.events e join public.crew_discord d on d.crew_id = e.crew_id
    where (d.webhook_url is not null or (d.bot_token is not null and d.channel_id is not null)) and d.post_photos and e.status in ('scheduled', 'closed')
      and coalesce(e.end_date, e.event_date) between today - 2 and today - 1
      and not exists (select 1 from public.discord_log l where l.kind = 'photos' and l.event_id = e.id)
  loop
    select 'Thanks to ' || string_agg(coalesce(p.callsign, split_part(p.full_name, ' ', 1)), ', ' order by p.full_name) || ' for busting at this one!'
      into thanks from public.event_workers(r.id) w join public.people p on p.id = w;
    st := public.dc_send_event(r.id, 'photos', thanks);
    insert into public.discord_log (crew_id, kind, event_id, status) values (r.crew_id, 'photos', r.id, st);
    n := n + 1;
  end loop;
  return 'posted ' || n;
end $$;
revoke all on function public.discord_run() from public, anon, authenticated;

-- A tap on a Going / Maybe / Can't button. Called only by the busters-discord-interactions function.
create or replace function public.discord_answer(p_app text, p_user text, p_username text, p_display text, p_nick text, p_event uuid, p_answer text)
returns json language plpgsql security definer set search_path = '' as $$
declare c uuid; e public.events_full; pid uuid; n int;
  norm text[] := array[lower(p_username), lower(p_display), lower(p_nick)];
begin
  select crew_id into c from public.crew_discord where app_id = p_app;
  if c is null then return json_build_object('status', 'unknown'); end if;
  select * into e from public.events_full where id = p_event and crew_id = c;
  if e.id is null or e.status <> 'scheduled' then return json_build_object('status', 'closed', 'title', e.title); end if;
  if e.event_date < (now() at time zone 'America/Los_Angeles')::date then return json_build_object('status', 'past', 'title', e.title); end if;
  if p_answer not in ('going', 'maybe', 'no') then return json_build_object('status', 'bad'); end if;

  select pp.person_id into pid from public.people_private pp join public.people p on p.id = pp.person_id
    where pp.crew_id = c and pp.discord_user_id = p_user and p.status in ('active', 'rookie');
  if pid is null then
    select count(*), min(pp.person_id::text)::uuid into n, pid from public.people_private pp join public.people p on p.id = pp.person_id
      where pp.crew_id = c and p.status in ('active', 'rookie') and pp.discord_user_id is null
        and lower(regexp_replace(trim(pp.discord), '^@|#0$', '')) = any (norm);
    if n = 1 then
      update public.people_private set discord_user_id = p_user where person_id = pid;
      delete from public.discord_unlinked where crew_id = c and discord_user_id = p_user;
    else
      insert into public.discord_unlinked (crew_id, discord_user_id, username, display_name, pending_event, pending_answer)
      values (c, p_user, p_username, coalesce(p_nick, p_display), p_event, p_answer)
      on conflict (crew_id, discord_user_id) do update set username = excluded.username, display_name = excluded.display_name,
        pending_event = excluded.pending_event, pending_answer = excluded.pending_answer, last_at = now();
      return json_build_object('status', 'unlinked', 'title', e.title);
    end if;
  end if;

  insert into public.rsvps (event_id, person_id, crew_id, answer, source)
    values (e.id, pid, c, p_answer, 'app')
  on conflict (event_id, person_id) do update set answer = excluded.answer, updated_at = now(), source = 'app',
    spot = case when excluded.answer = 'going' then public.rsvps.spot end;
  select * into e from public.events_full where id = p_event;
  return json_build_object('status', 'ok', 'title', e.title, 'answer', p_answer, 'count', public.dc_count(e.going, e.min_busters),
    'name', (select coalesce(callsign, split_part(full_name, ' ', 1)) from public.people where id = pid));
end $$;
revoke all on function public.discord_answer(text, text, text, text, text, uuid, text) from public, anon, authenticated;

-- Team tab: Discord accounts that tapped a button but couldn't be matched, and linking them.
create or replace function public.discord_unlinked_list(p_crew uuid)
returns table (discord_user_id text, username text, display_name text, pending text, last_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select u.discord_user_id, u.username, u.display_name,
    case when u.pending_answer is not null then initcap(replace(u.pending_answer, 'no', 'can''t')) || ' for ' || e.title end, u.last_at
  from public.discord_unlinked u left join public.events e on e.id = u.pending_event
  where u.crew_id = p_crew and public.can(p_crew, 'crew_admin') order by u.last_at desc;
$$;

create or replace function public.link_discord(p_crew uuid, p_discord_user text, p_person uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare u public.discord_unlinked;
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  select * into u from public.discord_unlinked where crew_id = p_crew and discord_user_id = p_discord_user;
  if p_person is null then
    delete from public.discord_unlinked where crew_id = p_crew and discord_user_id = p_discord_user; return;
  end if;
  if not exists (select 1 from public.people where id = p_person and crew_id = p_crew) then raise exception 'not in this crew'; end if;
  update public.people_private set discord_user_id = null where crew_id = p_crew and discord_user_id = p_discord_user;
  update public.people_private set discord_user_id = p_discord_user where person_id = p_person;
  if u.pending_event is not null and exists (select 1 from public.events where id = u.pending_event and status = 'scheduled') then
    insert into public.rsvps (event_id, person_id, crew_id, answer, source) values (u.pending_event, p_person, p_crew, u.pending_answer, 'app')
    on conflict (event_id, person_id) do update set answer = excluded.answer, updated_at = now(), source = 'app',
      spot = case when excluded.answer = 'going' then public.rsvps.spot end;
  end if;
  delete from public.discord_unlinked where crew_id = p_crew and discord_user_id = p_discord_user;
  perform public.log_action(p_crew, 'discord_link', 'person', p_person, 'Linked Discord ' || coalesce(u.username, p_discord_user));
end $$;
revoke all on function public.discord_unlinked_list(uuid), public.link_discord(uuid, text, uuid) from public, anon;
grant execute on function public.discord_unlinked_list(uuid), public.link_discord(uuid, text, uuid) to authenticated;
