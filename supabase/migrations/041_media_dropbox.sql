-- Jeff's event media drop: Dropbox connected once, a folder and upload link per event, a photo call in each
-- event's Discord thread after the event, photos posted in the thread copied into the folder, and a tracker
-- (who uploaded, who has none, who hasn't answered) with Send reminder and Mark complete.
-- Busters never stores the files. Dropbox fetches them straight from Discord (save_url) or people upload
-- through the Dropbox file request link. Keys and tokens live only here and are never sent to the app.

create table if not exists public.crew_media (
  crew_id uuid primary key references public.crews(id) on delete cascade,
  app_key text, app_secret text,
  oauth_state text, oauth_by uuid,
  refresh_token text, access_token text, access_expires timestamptz,
  account_name text, account_email text,
  root_folder text not null default '/LAGB Event Media',
  connected_by uuid, connected_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.crew_media enable row level security;

create table if not exists public.event_media (
  event_id uuid primary key references public.events(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  folder_path text, request_id text, request_url text,
  call_channel_id text, call_message_id text, called_at timestamptz,
  reminded_at timestamptz, auto_reminded boolean not null default false,
  completed_at timestamptz, completed_by uuid,
  last_message_id text
);
alter table public.event_media enable row level security;

create table if not exists public.media_answers (
  event_id uuid not null references public.events(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  answer text not null check (answer in ('uploaded', 'none')),
  files int not null default 0,
  at timestamptz not null default now(),
  primary key (event_id, person_id)
);
alter table public.media_answers enable row level security;

create table if not exists public.media_uploads (
  attachment_id text primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  person_id uuid,
  discord_user text, filename text, size bigint, status int,
  at timestamptz not null default now()
);
alter table public.media_uploads enable row level security;

-- ---------- Dropbox plumbing ----------

create or replace function public.dbx_token(p_crew uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m public.crew_media; r record; j jsonb;
begin
  select * into m from public.crew_media where crew_id = p_crew;
  if m.refresh_token is null then return null; end if;
  if m.access_token is not null and m.access_expires > now() + interval '5 minutes' then return m.access_token; end if;
  select status, content into r from extensions.http_post('https://api.dropboxapi.com/oauth2/token',
    'grant_type=refresh_token&refresh_token=' || m.refresh_token || '&client_id=' || m.app_key || '&client_secret=' || m.app_secret,
    'application/x-www-form-urlencoded');
  if r.status <> 200 then return null; end if;
  j := r.content::jsonb;
  update public.crew_media set access_token = j->>'access_token',
    access_expires = now() + make_interval(secs => coalesce((j->>'expires_in')::int, 14400)) where crew_id = p_crew;
  return j->>'access_token';
exception when others then return null;
end $$;
revoke all on function public.dbx_token(uuid) from public, anon, authenticated;

create or replace function public.dbx_call(p_crew uuid, p_endpoint text, p_body jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare t text; r record;
begin
  t := public.dbx_token(p_crew);
  if t is null then return jsonb_build_object('status', 401); end if;
  select status, content into r from extensions.http(('POST', 'https://api.dropboxapi.com/2/' || p_endpoint,
    array[extensions.http_header('Authorization', 'Bearer ' || t)], 'application/json', p_body::text)::extensions.http_request);
  return jsonb_build_object('status', r.status, 'body', case when r.content ~ '^\s*[\{\[]' then r.content::jsonb end, 'text', left(r.content, 300));
exception when others then return jsonb_build_object('status', -1);
end $$;
revoke all on function public.dbx_call(uuid, text, jsonb) from public, anon, authenticated;

-- Folder and upload link for an event (made once).
create or replace function public.media_prepare(p_event uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare e public.events; m public.crew_media; em public.event_media; folder text; r jsonb;
begin
  select * into e from public.events where id = p_event;
  select * into m from public.crew_media where crew_id = e.crew_id;
  if m.refresh_token is null then return null; end if;
  insert into public.event_media (event_id, crew_id) values (p_event, e.crew_id) on conflict do nothing;
  select * into em from public.event_media where event_id = p_event;
  if em.request_url is not null then return to_jsonb(em); end if;
  folder := coalesce(em.folder_path, rtrim(m.root_folder, '/') || '/' || to_char(e.event_date, 'YYYY-MM-DD') || ' ' ||
    left(btrim(regexp_replace(e.title, '[\\/:*?"<>|]+', ' ', 'g')), 80));
  r := public.dbx_call(e.crew_id, 'files/create_folder_v2', jsonb_build_object('path', folder, 'autorename', false));
  if (r->>'status')::int not in (200, 409) then return jsonb_build_object('error', 'folder ' || (r->>'status') || ' ' || coalesce(r->>'text', '')); end if;
  r := public.dbx_call(e.crew_id, 'file_requests/create', jsonb_build_object('title', left(e.title || ' photos and videos', 140), 'destination', folder, 'open', true));
  if (r->>'status')::int <> 200 then
    update public.event_media set folder_path = folder where event_id = p_event;
    return jsonb_build_object('error', 'file request ' || (r->>'status') || ' ' || coalesce(r->>'text', ''));
  end if;
  update public.event_media set folder_path = folder, request_id = r->'body'->>'id', request_url = r->'body'->>'url' where event_id = p_event;
  select * into em from public.event_media where event_id = p_event;
  return to_jsonb(em);
end $$;
revoke all on function public.media_prepare(uuid) from public, anon, authenticated;

-- ---------- The photo call ----------

create or replace function public.media_call_payload(p_event uuid, p_done boolean) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.events; em public.event_media; who text; ids jsonb; crew text; btns jsonb;
begin
  select * into e from public.events where id = p_event;
  select * into em from public.event_media where event_id = p_event;
  select c.short_name into crew from public.crews c where c.id = e.crew_id;
  select string_agg(coalesce('<@' || pp.discord_user_id || '>', coalesce(p.callsign, split_part(p.full_name, ' ', 1))), ' ' order by p.full_name),
         coalesce(jsonb_agg(pp.discord_user_id) filter (where pp.discord_user_id is not null), '[]')
    into who, ids
    from public.event_workers(p_event) w join public.people p on p.id = w left join public.people_private pp on pp.person_id = w;
  btns := jsonb_build_array(jsonb_build_object('type', 2, 'style', 5, 'label', 'Upload photos', 'emoji', jsonb_build_object('name', '📷'), 'url', em.request_url));
  if not p_done then btns := btns || jsonb_build_object('type', 2, 'style', 2, 'label', 'No photos from me', 'custom_id', 'photos:' || p_event || ':none'); end if;
  return jsonb_build_object(
    'content', case when p_done or who is null then null else 'Thanks for busting! ' || who end,
    'embeds', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('color', case when p_done then 5763719 else 3908599 end,
      'author', jsonb_build_object('name', case when p_done then '📷 Photos collected · thanks everyone!' else '📷 Photo call' end,
                                   'icon_url', 'https://deftspyder.github.io/busters/icons/icon-192.png'),
      'title', left(e.title, 250),
      'description', public.dc_day(e.event_date) || E'\n\n' || case when p_done
        then 'We have what we need. Still got a great shot? The upload link stays open.'
        else 'Got photos or videos from this one? Post them right here in the thread and they go straight to our media folder, or tap **Upload photos**.' || E'\n' || 'Files over 10 MB? Use the Upload photos link instead.' || E'\n' || 'Nothing to send? Tap **No photos from me** so we know.' end,
      'footer', jsonb_build_object('text', coalesce(crew, '') || ' · Busters')))),
    'components', jsonb_build_array(jsonb_build_object('type', 1, 'components', btns)),
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array(), 'users', ids));
end $$;
revoke all on function public.media_call_payload(uuid, boolean) from public, anon, authenticated;

create or replace function public.media_post_call(p_event uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events; em public.event_media; th text; r jsonb; mid text;
begin
  select * into e from public.events where id = p_event;
  if public.media_prepare(p_event) ? 'error' then return -2; end if;
  select * into em from public.event_media where event_id = p_event;
  if em.called_at is not null then return 0; end if;
  th := public.dc_ensure_thread(p_event);
  if th is null then return -3; end if;
  r := public.dc_http_json(e.crew_id, 'POST', '/channels/' || th || '/messages', public.media_call_payload(p_event, false));
  if (r->>'status')::int not between 200 and 299 then return (r->>'status')::int; end if;
  mid := r->'body'->>'id';
  perform public.dc_http(e.crew_id, 'PUT', '/channels/' || th || '/pins/' || mid, null);   -- needs Pin Messages; fine if not
  update public.event_media set call_channel_id = th, call_message_id = mid, called_at = now() where event_id = p_event;
  insert into public.discord_log (crew_id, kind, event_id, status) values (e.crew_id, 'photos', p_event, (r->>'status')::int) on conflict do nothing;
  return (r->>'status')::int;
end $$;
revoke all on function public.media_post_call(uuid) from public, anon, authenticated;

-- Copy attachments posted in event threads into the event's folder.
create or replace function public.media_harvest() returns int
language plpgsql security definer set search_path = '' as $$
declare em record; r jsonb; msg jsonb; a jsonb; pid uuid; n int := 0; calls int := 0; nm text; last text;
begin
  for em in select x.*, t.thread_id from public.event_media x join public.discord_threads t on t.event_id = x.event_id
            join public.crew_media m on m.crew_id = x.crew_id
            where x.called_at is not null and x.folder_path is not null and m.refresh_token is not null
              and x.called_at > now() - interval '45 days' loop
    exit when calls >= 20;
    r := public.dc_http_json(em.crew_id, 'GET', '/channels/' || em.thread_id || '/messages?limit=100' || coalesce('&after=' || em.last_message_id, ''), null);
    calls := calls + 1;
    continue when (r->>'status')::int <> 200 or jsonb_typeof(r->'body') <> 'array';
    last := em.last_message_id;
    for msg in select * from jsonb_array_elements(r->'body') order by (value->>'id')::numeric loop
      last := msg->>'id';
      continue when coalesce((msg->'author'->>'bot')::boolean, false);
      for a in select * from jsonb_array_elements(coalesce(msg->'attachments', '[]')) loop
        continue when exists (select 1 from public.media_uploads u where u.attachment_id = a->>'id');
        select pp.person_id into pid from public.people_private pp where pp.crew_id = em.crew_id and pp.discord_user_id = msg->'author'->>'id';
        nm := to_char((msg->>'timestamp')::timestamptz at time zone 'America/Los_Angeles', 'YYYY-MM-DD HHMI') || ' '
              || left(regexp_replace(coalesce(msg->'author'->>'global_name', msg->'author'->>'username', 'someone'), '[\\/:*?"<>|]+', '', 'g'), 40) || ' '
              || left(regexp_replace(a->>'filename', '[\\/:*?"<>|]+', '_', 'g'), 100);
        r := public.dbx_call(em.crew_id, 'files/save_url', jsonb_build_object('path', em.folder_path || '/' || nm, 'url', a->>'url'));
        insert into public.media_uploads (attachment_id, event_id, person_id, discord_user, filename, size, status)
          values (a->>'id', em.event_id, pid, msg->'author'->>'username', a->>'filename', (a->>'size')::bigint, (r->>'status')::int) on conflict do nothing;
        if pid is not null and (r->>'status')::int = 200 then
          insert into public.media_answers (event_id, person_id, answer, files) values (em.event_id, pid, 'uploaded', 1)
            on conflict (event_id, person_id) do update set answer = 'uploaded', files = public.media_answers.files + 1, at = now();
        end if;
        n := n + 1;
      end loop;
    end loop;
    if last is distinct from em.last_message_id then update public.event_media set last_message_id = last where event_id = em.event_id; end if;
  end loop;
  return n;
end $$;
revoke all on function public.media_harvest() from public, anon, authenticated;

-- Reminder in the thread, pinging only who hasn't answered.
create or replace function public.media_send_reminder(p_event uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events; em public.event_media; who text; ids jsonb; st int;
begin
  select * into e from public.events where id = p_event;
  select * into em from public.event_media where event_id = p_event;
  if em.call_channel_id is null or em.completed_at is not null then return 0; end if;
  select string_agg(coalesce('<@' || pp.discord_user_id || '>', coalesce(p.callsign, split_part(p.full_name, ' ', 1))), ' ' order by p.full_name),
         coalesce(jsonb_agg(pp.discord_user_id) filter (where pp.discord_user_id is not null), '[]')
    into who, ids
    from public.event_workers(p_event) w join public.people p on p.id = w left join public.people_private pp on pp.person_id = w
    where not exists (select 1 from public.media_answers ma where ma.event_id = p_event and ma.person_id = w);
  if who is null then return 0; end if;
  st := public.dc_http(e.crew_id, 'POST', '/channels/' || em.call_channel_id || '/messages', jsonb_build_object(
    'content', 'Friendly reminder for **' || e.title || '**: ' || who || E'\nPost your photos here, use the Upload photos link on the pinned message, or tap No photos from me.',
    'message_reference', jsonb_build_object('message_id', em.call_message_id, 'fail_if_not_exists', false),
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array(), 'users', ids)));
  update public.event_media set reminded_at = now() where event_id = p_event;
  return st;
end $$;
revoke all on function public.media_send_reminder(uuid) from public, anon, authenticated;

-- Runner: photo call the day after an event (10 am on), one automatic reminder 3 days after the call, harvest.
create or replace function public.media_run() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  n := n + public.media_harvest();
  for r in select e.id from public.events e
           join public.crew_media m on m.crew_id = e.crew_id and m.refresh_token is not null
           join public.crew_discord d on d.crew_id = e.crew_id and d.bot_token is not null and d.post_photos
           left join public.event_media em on em.event_id = e.id
           where e.status in ('scheduled', 'closed') and coalesce(e.end_date, e.event_date) between today - 3 and today - 1
             and em.called_at is null and not public.dc_quiet(d.quiet_from, d.quiet_to)
             and extract(hour from now() at time zone 'America/Los_Angeles') >= 10
             and exists (select 1 from public.event_workers(e.id)) loop
    perform public.media_post_call(r.id); n := n + 1;
  end loop;
  for r in select em.event_id from public.event_media em join public.crew_discord d on d.crew_id = em.crew_id
           where em.called_at < now() - interval '3 days' and not em.auto_reminded and em.completed_at is null
             and not public.dc_quiet(d.quiet_from, d.quiet_to) loop
    perform public.media_send_reminder(r.event_id);
    update public.event_media set auto_reminded = true where event_id = r.event_id; n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.media_run() from public, anon, authenticated;

-- "No photos from me" from Discord.
create or replace function public.media_answer_discord(p_app text, p_user text, p_username text, p_display text, p_nick text, p_event uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare m json; c uuid; pid uuid; t text;
begin
  m := public.discord_match(p_app, p_user, p_username, p_display, p_nick);
  select crew_id into c from public.crew_discord where app_id = p_app;
  select title into t from public.events where id = p_event and crew_id = c;
  if t is null then return json_build_object('status', 'unknown'); end if;
  select person_id into pid from public.people_private where crew_id = c and discord_user_id = p_user;
  if pid is null then return json_build_object('status', 'unlinked', 'title', t); end if;
  insert into public.media_answers (event_id, person_id, answer) values (p_event, pid, 'none')
    on conflict (event_id, person_id) do update set answer = case when public.media_answers.files > 0 then 'uploaded' else 'none' end, at = now();
  return json_build_object('status', 'ok', 'title', t);
end $$;
revoke all on function public.media_answer_discord(text, text, text, text, text, uuid) from public, anon, authenticated;

-- ---------- What the app calls (Media dashboard: webmaster or crew admin) ----------

create or replace function public.media_status(p_crew uuid) returns json
language plpgsql stable security definer set search_path = '' as $$
declare m public.crew_media; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if not public.can(p_crew, 'webmaster') then raise exception 'not allowed'; end if;
  select * into m from public.crew_media where crew_id = p_crew;
  return json_build_object(
    'has_app', m.app_key is not null, 'connected', m.refresh_token is not null, 'account', m.account_name, 'email', m.account_email,
    'root', coalesce(m.root_folder, '/LAGB Event Media'), 'connected_at', m.connected_at, 'is_admin', public.can(p_crew, 'crew_admin'),
    'events', (select coalesce(json_agg(x order by x.event_date desc), '[]') from (
      select e.id, e.title, e.event_date, em.called_at, em.completed_at, em.request_url, em.folder_path,
        (select count(*) from public.event_workers(e.id)) as went,
        (select count(*) from public.media_answers ma where ma.event_id = e.id and ma.person_id in (select public.event_workers(e.id))) as answered,
        (select coalesce(sum(files), 0) from public.media_answers ma where ma.event_id = e.id) as files
      from public.events e left join public.event_media em on em.event_id = e.id
      where e.crew_id = p_crew and e.status in ('scheduled', 'closed') and coalesce(e.end_date, e.event_date) < today
        and e.event_date > today - 90 and exists (select 1 from public.event_workers(e.id))) x));
end $$;

create or replace function public.media_event(p_event uuid) returns json
language plpgsql stable security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event;
  if not public.can(e.crew_id, 'webmaster') then raise exception 'not allowed'; end if;
  return json_build_object('people', (select coalesce(json_agg(json_build_object('id', p.id, 'name', coalesce(p.callsign, p.full_name),
      'answer', ma.answer, 'files', coalesce(ma.files, 0)) order by p.full_name), '[]')
    from public.event_workers(p_event) w join public.people p on p.id = w left join public.media_answers ma on ma.event_id = p_event and ma.person_id = w),
    'media', (select to_json(em) from public.event_media em where em.event_id = p_event));
end $$;

create or replace function public.media_set_app(p_crew uuid, p_key text, p_secret text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  if coalesce(trim(p_key), '') = '' or coalesce(trim(p_secret), '') = '' then raise exception 'Paste both the App key and the App secret'; end if;
  insert into public.crew_media (crew_id, app_key, app_secret) values (p_crew, trim(p_key), trim(p_secret))
  on conflict (crew_id) do update set app_key = excluded.app_key, app_secret = excluded.app_secret, updated_at = now();
  perform public.log_action(p_crew, 'media_app', 'crew', p_crew, 'Saved the Dropbox app keys');
end $$;

create or replace function public.media_connect_url(p_crew uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare m public.crew_media; st text := encode(extensions.gen_random_bytes(18), 'hex');
begin
  if not public.can(p_crew, 'webmaster') then raise exception 'not allowed'; end if;
  select * into m from public.crew_media where crew_id = p_crew;
  if m.app_key is null then raise exception 'A crew admin needs to add the Dropbox app keys first'; end if;
  update public.crew_media set oauth_state = st, oauth_by = public.me(p_crew) where crew_id = p_crew;
  return 'https://www.dropbox.com/oauth2/authorize?client_id=' || m.app_key || '&response_type=code&token_access_type=offline&state=' || st
    || '&redirect_uri=https%3A%2F%2Ffwptdvoifkfljblyziva.supabase.co%2Ffunctions%2Fv1%2Fbusters-dropbox';
end $$;

-- Called by the busters-dropbox function with Dropbox's code (service role only).
create or replace function public.media_oauth_finish(p_state text, p_code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m public.crew_media; r record; j jsonb; t text;
begin
  select * into m from public.crew_media where oauth_state = p_state;
  if m.crew_id is null then return 'unknown'; end if;
  select status, content into r from extensions.http_post('https://api.dropboxapi.com/oauth2/token',
    'grant_type=authorization_code&code=' || p_code || '&client_id=' || m.app_key || '&client_secret=' || m.app_secret
    || '&redirect_uri=https%3A%2F%2Ffwptdvoifkfljblyziva.supabase.co%2Ffunctions%2Fv1%2Fbusters-dropbox', 'application/x-www-form-urlencoded');
  if r.status <> 200 then return 'token ' || r.status || ' ' || left(r.content, 200); end if;
  j := r.content::jsonb;
  update public.crew_media set refresh_token = j->>'refresh_token', access_token = j->>'access_token',
    access_expires = now() + make_interval(secs => coalesce((j->>'expires_in')::int, 14400)),
    oauth_state = null, connected_by = m.oauth_by, connected_at = now(), updated_at = now() where crew_id = m.crew_id;
  select status, content into r from extensions.http(('POST', 'https://api.dropboxapi.com/2/users/get_current_account',
    array[extensions.http_header('Authorization', 'Bearer ' || (j->>'access_token'))], null, null)::extensions.http_request);
  if r.status = 200 then
    update public.crew_media set account_name = r.content::jsonb->'name'->>'display_name', account_email = r.content::jsonb->>'email' where crew_id = m.crew_id;
  end if;
  update public.crew_discord set post_photos = true where crew_id = m.crew_id;
  perform public.dbx_call(m.crew_id, 'files/create_folder_v2', jsonb_build_object('path', m.root_folder, 'autorename', false));
  return 'ok';
end $$;
revoke all on function public.media_oauth_finish(text, text) from public, anon, authenticated;

create or replace function public.media_disconnect(p_crew uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'webmaster') then raise exception 'not allowed'; end if;
  update public.crew_media set refresh_token = null, access_token = null, access_expires = null, account_name = null, account_email = null where crew_id = p_crew;
  perform public.log_action(p_crew, 'media_disconnect', 'crew', p_crew, 'Disconnected Dropbox');
end $$;

create or replace function public.media_remind(p_event uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events; st int;
begin
  select * into e from public.events where id = p_event;
  if not public.can(e.crew_id, 'webmaster') then raise exception 'not allowed'; end if;
  st := public.media_send_reminder(p_event);
  perform public.log_action(e.crew_id, 'media_remind', 'event', p_event, 'Sent a photo reminder for ' || e.title);
  return st;
end $$;

create or replace function public.media_complete(p_event uuid, p_done boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare e public.events; em public.event_media;
begin
  select * into e from public.events where id = p_event;
  if not public.can(e.crew_id, 'webmaster') then raise exception 'not allowed'; end if;
  update public.event_media set completed_at = case when p_done then now() end, completed_by = case when p_done then public.me(e.crew_id) end where event_id = p_event;
  select * into em from public.event_media where event_id = p_event;
  if em.call_message_id is not null then
    perform public.dc_http(e.crew_id, 'PATCH', '/channels/' || em.call_channel_id || '/messages/' || em.call_message_id,
      (public.media_call_payload(p_event, p_done) - 'content' - 'allowed_mentions'));
  end if;
  perform public.log_action(e.crew_id, 'media_complete', 'event', p_event, case when p_done then 'Marked photos complete for ' else 'Reopened photos for ' end || e.title);
end $$;

-- Post the photo call now (from the tracker), instead of waiting for the morning after.
create or replace function public.media_call_now(p_event uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event;
  if not public.can(e.crew_id, 'webmaster') then raise exception 'not allowed'; end if;
  return public.media_post_call(p_event);
end $$;

revoke all on function public.media_status(uuid), public.media_event(uuid), public.media_set_app(uuid, text, text), public.media_connect_url(uuid),
  public.media_disconnect(uuid), public.media_remind(uuid), public.media_complete(uuid, boolean), public.media_call_now(uuid) from public, anon;
grant execute on function public.media_status(uuid), public.media_event(uuid), public.media_set_app(uuid, text, text), public.media_connect_url(uuid),
  public.media_disconnect(uuid), public.media_remind(uuid), public.media_complete(uuid, boolean), public.media_call_now(uuid) to authenticated;

-- The old "reply here" photo call is replaced by the thread version.
do $$ declare d text; begin
  d := pg_get_functiondef('public.discord_run()'::regprocedure);
  if position('media_run' in d) = 0 then
    d := replace(d, 'n := n + public.dc_interest_dms();', 'n := n + public.dc_interest_dms();
  n := n + public.media_run();');
    d := replace(d, $x$      where e.crew_id = d.crew_id and d.post_photos and e.status in ('scheduled', 'closed')$x$,
                    $x$      where e.crew_id = d.crew_id and d.post_photos and false and e.status in ('scheduled', 'closed')$x$);
    execute d;
  end if;
end $$;
