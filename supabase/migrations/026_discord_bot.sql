-- Discord bot: Busters can post as its own bot (bot token plus a channel id) instead of a webhook.
-- The token is a secret: it lives only here, is never returned to the app, and only crew admins can set it.
alter table public.crew_discord
  add column if not exists bot_token text,
  add column if not exists channel_id text,
  add column if not exists bot_name text,
  add column if not exists channel_name text,
  add column if not exists bot_checked_at timestamptz,
  add column if not exists app_id text;

-- Sends one message, through the bot if it's set up, otherwise the webhook. Internal only.
-- Also sets busters.dc_msg (message id:channel) and busters.dc_text for the log row that follows (see 027).
create or replace function public.discord_send(p_crew uuid, p_text text) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare d public.crew_discord; r record; body text;
begin
  perform set_config('busters.dc_msg', '', true);
  perform set_config('busters.dc_text', left(p_text, 200), true);
  select * into d from public.crew_discord where crew_id = p_crew;
  if d.crew_id is null then return null; end if;
  body := json_build_object('content', left(p_text, 1900),
            'allowed_mentions', json_build_object('parse', json_build_array()))::text;
  if d.bot_token is not null and d.channel_id is not null then
    select status, content into r from extensions.http((
      'POST', 'https://discord.com/api/v10/channels/' || d.channel_id || '/messages',
      array[extensions.http_header('Authorization', 'Bot ' || d.bot_token),
            extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
      'application/json', body)::extensions.http_request);
    if r.status between 200 and 299 then
      perform set_config('busters.dc_msg', coalesce(r.content::jsonb->>'id', '') || ':' || d.channel_id, true);
    end if;
    return r.status;
  elsif d.webhook_url is not null then
    select status into r from extensions.http_post(d.webhook_url,
      (body::jsonb || '{"username":"Busters"}'::jsonb)::text, 'application/json');
    return r.status;
  end if;
  return null;
exception when others then return -1;
end $$;
revoke all on function public.discord_send(uuid, text) from public, anon, authenticated;

-- p_token: null keeps the current token, '' removes the bot.
create or replace function public.set_discord_bot(p_crew uuid, p_token text, p_channel text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  if p_token is not null and p_token <> '' and (length(p_token) < 50 or p_token !~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') then
    raise exception 'That does not look like a Discord bot token';
  end if;
  if p_channel is not null and p_channel <> '' and p_channel !~ '^[0-9]{15,22}$' then
    raise exception 'The channel ID should be a long number (right-click the channel, Copy Channel ID)';
  end if;
  insert into public.crew_discord (crew_id) values (p_crew) on conflict (crew_id) do nothing;
  update public.crew_discord set
    bot_token = case when p_token is null then bot_token else nullif(p_token, '') end,
    channel_id = case when p_token = '' then null when p_channel is null then channel_id else nullif(p_channel, '') end,
    bot_name = case when p_token is not null then null else bot_name end,
    channel_name = case when p_token is not null or p_channel is not null then null else channel_name end,
    bot_checked_at = case when p_token is not null or p_channel is not null then null else bot_checked_at end,
    updated_at = now()
  where crew_id = p_crew;
  perform public.log_action(p_crew, 'discord_settings', 'crew', p_crew,
    case when p_token = '' then 'Removed the Discord bot' when p_token is not null then 'Set up the Discord bot' else 'Changed the Discord channel' end);
end $$;
revoke all on function public.set_discord_bot(uuid, text, text) from public, anon;
grant execute on function public.set_discord_bot(uuid, text, text) to authenticated;

create or replace function public.discord_settings(p_crew uuid) returns json
language sql stable security definer set search_path = '' as $$
  select case when public.can(p_crew, 'crew_admin') then (
    select json_build_object('has_hook', d.webhook_url is not null, 'tail', right(d.webhook_url, 4),
      'has_bot', d.bot_token is not null, 'app_id', d.app_id, 'channel_id', d.channel_id, 'bot_name', d.bot_name, 'channel_name', d.channel_name, 'checked', d.bot_checked_at,
      'post_short', coalesce(d.post_short, true), 'short_days', coalesce(d.short_days, 3), 'post_photos', coalesce(d.post_photos, true),
      'last', (select json_build_object('kind', l.kind, 'status', l.status, 'at', l.at) from public.discord_log l
               where l.crew_id = p_crew order by l.at desc limit 1))
    from (select p_crew as c) x left join public.crew_discord d on d.crew_id = x.c) end;
$$;

-- The posting rules now run when either a bot or a webhook is set up.
create or replace function public.discord_run() returns text
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
  hr int := extract(hour from now() at time zone 'America/Los_Angeles');
begin
  if hr < 9 or hr >= 21 then return 'quiet hours'; end if;
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
      || ' (' || r.going || ' of ' || r.min_busters || ' so far). Can you make it? ' || public.event_link(r.id));
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
