-- Event photos can now end up in a Google Drive instead of Dropbox (a per-crew choice).
-- LAGB: people upload through a Dropbox upload link (no sign-in) into Bill's Dropbox, or post in the event's
-- Discord thread. Busters copies everything into "Busters Photo Drop" in the crew's Google Drive (one folder per
-- event) and then deletes the Dropbox copy. Photos from Discord go straight to Drive.
-- Google is connected once through a one-time link that doesn't need a Busters account (Amy, as lagbevents@gmail.com).
-- Google scope is drive.file: Busters only ever sees the folders and files it created itself.
-- The copying itself happens in the busters-media-copy edge function (files are streamed, never stored).

-- App-wide keys (Google OAuth client, the copy function's shared secret). No policies: nothing in the app can read it.
create table if not exists public.app_keys (name text primary key, value text not null, updated_at timestamptz not null default now());
alter table public.app_keys enable row level security;
insert into public.app_keys (name, value) values ('media_copy_secret', encode(extensions.gen_random_bytes(24), 'hex')) on conflict do nothing;

alter table public.crew_media
  add column if not exists dest text not null default 'dropbox',
  add column if not exists g_refresh_token text, add column if not exists g_access_token text, add column if not exists g_access_expires timestamptz,
  add column if not exists g_email text, add column if not exists g_root_id text,
  add column if not exists g_root_name text not null default 'Busters Photo Drop',
  add column if not exists g_link_token text, add column if not exists g_link_expires timestamptz, add column if not exists g_link_by uuid,
  add column if not exists g_state text, add column if not exists g_connected_at timestamptz;
do $$ begin
  alter table public.crew_media add constraint crew_media_dest check (dest in ('dropbox', 'gdrive'));
exception when duplicate_object then null; end $$;

alter table public.event_media add column if not exists g_folder_id text;

-- Copy queue. Rows with dest = 'gdrive' and copied_at null are waiting for the copy function.
alter table public.media_uploads
  add column if not exists crew_id uuid,
  add column if not exists source text not null default 'discord',
  add column if not exists src_url text, add column if not exists dbx_path text,
  add column if not exists dest text, add column if not exists dest_id text,
  add column if not exists copied_at timestamptz, add column if not exists tries int not null default 0, add column if not exists err text;
create index if not exists media_uploads_pending on public.media_uploads (at) where dest = 'gdrive' and copied_at is null;

-- ---------- Google plumbing ----------

create or replace function public.gd_token(p_crew uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m public.crew_media; r record; j jsonb; cid text; sec text;
begin
  select * into m from public.crew_media where crew_id = p_crew;
  if m.g_refresh_token is null then return null; end if;
  if m.g_access_token is not null and m.g_access_expires > now() + interval '5 minutes' then return m.g_access_token; end if;
  select value into cid from public.app_keys where name = 'google_client_id';
  select value into sec from public.app_keys where name = 'google_client_secret';
  select status, content into r from extensions.http_post('https://oauth2.googleapis.com/token',
    'grant_type=refresh_token&refresh_token=' || extensions.urlencode(m.g_refresh_token) || '&client_id=' || extensions.urlencode(cid)
    || '&client_secret=' || extensions.urlencode(sec), 'application/x-www-form-urlencoded');
  if r.status <> 200 then return null; end if;
  j := r.content::jsonb;
  update public.crew_media set g_access_token = j->>'access_token',
    g_access_expires = now() + make_interval(secs => coalesce((j->>'expires_in')::int, 3600)) where crew_id = p_crew;
  return j->>'access_token';
exception when others then return null;
end $$;
revoke all on function public.gd_token(uuid) from public, anon, authenticated;
grant execute on function public.gd_token(uuid), public.dbx_token(uuid) to service_role;

-- One-time connect link (webmaster or crew admin makes it, anyone with it can connect, good for 7 days).
create or replace function public.media_google_link(p_crew uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare t text := encode(extensions.gen_random_bytes(18), 'hex');
begin
  if not public.can(p_crew, 'webmaster') then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.app_keys where name = 'google_client_id') then raise exception 'A crew admin needs to add the Google app keys first'; end if;
  insert into public.crew_media (crew_id) values (p_crew) on conflict do nothing;
  update public.crew_media set g_link_token = t, g_link_expires = now() + interval '7 days', g_link_by = public.me(p_crew), updated_at = now() where crew_id = p_crew;
  perform public.log_action(p_crew, 'media_google_link', 'crew', p_crew, 'Made a Google Drive connect link');
  return 'https://busters.app/connect.html?t=' || t;
end $$;

-- What connect.html shows before the person taps Continue (no sign-in).
create or replace function public.media_google_link_info(p_token text) returns json
language plpgsql stable security definer set search_path = '' as $$
declare m public.crew_media; c text;
begin
  select * into m from public.crew_media where g_link_token = p_token and g_link_expires > now();
  if m.crew_id is null then return json_build_object('ok', false); end if;
  select name into c from public.crews where id = m.crew_id;
  return json_build_object('ok', true, 'crew', c, 'folder', m.g_root_name);
end $$;
revoke all on function public.media_google_link_info(text) from public;
grant execute on function public.media_google_link_info(text) to anon, authenticated;

-- busters-google function: link token -> Google's consent page.
create or replace function public.media_google_start(p_token text) returns text
language plpgsql security definer set search_path = '' as $$
declare m public.crew_media; cid text; st text := encode(extensions.gen_random_bytes(18), 'hex');
begin
  select * into m from public.crew_media where g_link_token = p_token and g_link_expires > now();
  if m.crew_id is null then return null; end if;
  select value into cid from public.app_keys where name = 'google_client_id';
  update public.crew_media set g_state = st where crew_id = m.crew_id;
  return 'https://accounts.google.com/o/oauth2/v2/auth?client_id=' || extensions.urlencode(cid) || '&response_type=code&access_type=offline&prompt=consent'
    || '&include_granted_scopes=true&state=' || st
    || '&scope=' || extensions.urlencode('openid email https://www.googleapis.com/auth/drive.file')
    || '&redirect_uri=' || extensions.urlencode('https://fwptdvoifkfljblyziva.supabase.co/functions/v1/busters-google');
end $$;
revoke all on function public.media_google_start(text) from public, anon, authenticated;
grant execute on function public.media_google_start(text) to service_role;

-- busters-google function: Google's code -> lasting connection. The link is used up.
create or replace function public.media_google_finish(p_state text, p_code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m public.crew_media; r record; j jsonb; cid text; sec text; em text;
begin
  select * into m from public.crew_media where g_state = p_state and g_link_expires > now();
  if m.crew_id is null then return 'expired'; end if;
  select value into cid from public.app_keys where name = 'google_client_id';
  select value into sec from public.app_keys where name = 'google_client_secret';
  select status, content into r from extensions.http_post('https://oauth2.googleapis.com/token',
    'grant_type=authorization_code&code=' || extensions.urlencode(p_code) || '&client_id=' || extensions.urlencode(cid)
    || '&client_secret=' || extensions.urlencode(sec)
    || '&redirect_uri=' || extensions.urlencode('https://fwptdvoifkfljblyziva.supabase.co/functions/v1/busters-google'), 'application/x-www-form-urlencoded');
  if r.status <> 200 then return 'token ' || r.status || ' ' || left(r.content, 200); end if;
  j := r.content::jsonb;
  if j->>'refresh_token' is null then return 'norefresh'; end if;
  if position('drive.file' in coalesce(j->>'scope', '')) = 0 then return 'noscope'; end if;
  select status, content into r from extensions.http(('GET', 'https://openidconnect.googleapis.com/v1/userinfo',
    array[extensions.http_header('Authorization', 'Bearer ' || (j->>'access_token'))], null, null)::extensions.http_request);
  if r.status = 200 then em := r.content::jsonb->>'email'; end if;
  update public.crew_media set g_refresh_token = j->>'refresh_token', g_access_token = j->>'access_token',
    g_access_expires = now() + make_interval(secs => coalesce((j->>'expires_in')::int, 3600)), g_email = em,
    g_root_id = case when g_email is distinct from em then null else g_root_id end,
    g_state = null, g_link_token = null, g_link_expires = null, g_connected_at = now(), dest = 'gdrive', updated_at = now()
  where crew_id = m.crew_id;
  perform public.log_action(m.crew_id, 'media_google', 'crew', m.crew_id, 'Google Drive connected as ' || coalesce(em, 'unknown'));
  return 'ok';
end $$;
revoke all on function public.media_google_finish(text, text) from public, anon, authenticated;
grant execute on function public.media_google_finish(text, text) to service_role;

create or replace function public.media_google_disconnect(p_crew uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'webmaster') then raise exception 'not allowed'; end if;
  update public.crew_media set g_refresh_token = null, g_access_token = null, g_access_expires = null, dest = 'dropbox', updated_at = now() where crew_id = p_crew;
  perform public.log_action(p_crew, 'media_google_off', 'crew', p_crew, 'Disconnected Google Drive');
end $$;

create or replace function public.media_set_google_app(p_crew uuid, p_id text, p_secret text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  if coalesce(trim(p_id), '') = '' or coalesce(trim(p_secret), '') = '' then raise exception 'Paste both the Client ID and the Client secret'; end if;
  insert into public.app_keys (name, value) values ('google_client_id', trim(p_id)), ('google_client_secret', trim(p_secret))
  on conflict (name) do update set value = excluded.value, updated_at = now();
  perform public.log_action(p_crew, 'media_google_app', 'crew', p_crew, 'Saved the Google app keys');
end $$;

revoke all on function public.media_google_link(uuid), public.media_google_disconnect(uuid), public.media_set_google_app(uuid, text, text) from public, anon;
grant execute on function public.media_google_link(uuid), public.media_google_disconnect(uuid), public.media_set_google_app(uuid, text, text) to authenticated;

-- ---------- Discord thread photos: straight to Drive when the crew uses Drive ----------

create or replace function public.media_harvest() returns int
language plpgsql security definer set search_path = '' as $$
declare em record; r jsonb; msg jsonb; a jsonb; pid uuid; n int := 0; calls int := 0; nm text; last text;
begin
  for em in select x.*, t.thread_id, m.dest from public.event_media x join public.discord_threads t on t.event_id = x.event_id
            join public.crew_media m on m.crew_id = x.crew_id
            where x.called_at is not null and x.folder_path is not null
              and ((m.dest = 'dropbox' and m.refresh_token is not null) or (m.dest = 'gdrive' and m.g_refresh_token is not null))
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
        if em.dest = 'gdrive' then
          -- Queued; busters-media-copy streams it from Discord into Drive and counts it for the person when it lands.
          insert into public.media_uploads (attachment_id, crew_id, event_id, person_id, discord_user, filename, size, source, src_url, dest)
            values (a->>'id', em.crew_id, em.event_id, pid, msg->'author'->>'username', nm, (a->>'size')::bigint, 'discord', a->>'url', 'gdrive')
            on conflict do nothing;
        else
          r := public.dbx_call(em.crew_id, 'files/save_url', jsonb_build_object('path', em.folder_path || '/' || nm, 'url', a->>'url'));
          insert into public.media_uploads (attachment_id, crew_id, event_id, person_id, discord_user, filename, size, status, source, dest)
            values (a->>'id', em.crew_id, em.event_id, pid, msg->'author'->>'username', a->>'filename', (a->>'size')::bigint, (r->>'status')::int, 'discord', 'dropbox')
            on conflict do nothing;
          if pid is not null and (r->>'status')::int = 200 then
            insert into public.media_answers (event_id, person_id, answer, files) values (em.event_id, pid, 'uploaded', 1)
              on conflict (event_id, person_id) do update set answer = 'uploaded', files = public.media_answers.files + 1, at = now();
          end if;
        end if;
        n := n + 1;
      end loop;
    end loop;
    if last is distinct from em.last_message_id then update public.event_media set last_message_id = last where event_id = em.event_id; end if;
  end loop;
  return n;
end $$;
revoke all on function public.media_harvest() from public, anon, authenticated;

-- ---------- Upload-link files: find new files in the Dropbox event folders and queue them for Drive ----------

create or replace function public.media_scan_dropbox() returns int
language plpgsql security definer set search_path = '' as $$
declare em record; r jsonb; f jsonb; n int := 0; calls int := 0;
begin
  for em in select x.* from public.event_media x join public.crew_media m on m.crew_id = x.crew_id
            where m.dest = 'gdrive' and m.g_refresh_token is not null and m.refresh_token is not null
              and x.folder_path is not null and x.request_url is not null and x.called_at > now() - interval '45 days' loop
    exit when calls >= 20;
    r := public.dbx_call(em.crew_id, 'files/list_folder', jsonb_build_object('path', em.folder_path, 'limit', 200));
    calls := calls + 1;
    continue when (r->>'status')::int <> 200;
    for f in select * from jsonb_array_elements(coalesce(r->'body'->'entries', '[]')) loop
      continue when f->>'.tag' <> 'file';
      insert into public.media_uploads (attachment_id, crew_id, event_id, filename, size, source, dbx_path, dest)
        values ('dbx:' || (f->>'id'), em.crew_id, em.event_id, left(f->>'name', 200), (f->>'size')::bigint, 'dropbox', f->>'path_lower', 'gdrive')
        on conflict do nothing;
      if found then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.media_scan_dropbox() from public, anon, authenticated;

-- ---------- What the copy function calls (service role only) ----------

create or replace function public.media_copy_jobs(p_secret text, p_limit int) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if p_secret is distinct from (select value from public.app_keys where name = 'media_copy_secret') then raise exception 'not allowed'; end if;
  return (select coalesce(jsonb_agg(x), '[]') from (
    select u.attachment_id as id, u.crew_id, u.event_id, u.source, u.src_url, u.dbx_path, u.filename, u.size, u.tries,
           m.g_root_id, m.g_root_name, em.g_folder_id,
           to_char(e.event_date, 'YYYY-MM-DD') || ' ' || left(btrim(regexp_replace(e.title, '[\\/:*?"<>|]+', ' ', 'g')), 80) as folder_name
    from public.media_uploads u join public.crew_media m on m.crew_id = u.crew_id
      join public.events e on e.id = u.event_id join public.event_media em on em.event_id = u.event_id
    where u.dest = 'gdrive' and u.copied_at is null and u.tries < 5 and m.g_refresh_token is not null
    order by u.at limit p_limit) x);
end $$;

create or replace function public.media_copy_token(p_secret text, p_crew uuid, p_which text) returns text
language plpgsql security definer set search_path = '' as $$
begin
  if p_secret is distinct from (select value from public.app_keys where name = 'media_copy_secret') then raise exception 'not allowed'; end if;
  return case p_which when 'google' then public.gd_token(p_crew) when 'dropbox' then public.dbx_token(p_crew) end;
end $$;

create or replace function public.media_copy_folder(p_secret text, p_crew uuid, p_event uuid, p_folder text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_secret is distinct from (select value from public.app_keys where name = 'media_copy_secret') then raise exception 'not allowed'; end if;
  if p_event is null then update public.crew_media set g_root_id = p_folder where crew_id = p_crew;
  else update public.event_media set g_folder_id = p_folder where event_id = p_event; end if;
end $$;

create or replace function public.media_copy_result(p_secret text, p_id text, p_dest_id text, p_err text) returns void
language plpgsql security definer set search_path = '' as $$
declare u public.media_uploads;
begin
  if p_secret is distinct from (select value from public.app_keys where name = 'media_copy_secret') then raise exception 'not allowed'; end if;
  if p_dest_id is null then
    update public.media_uploads set tries = tries + 1, err = left(p_err, 300) where attachment_id = p_id;
    return;
  end if;
  update public.media_uploads set copied_at = now(), dest_id = p_dest_id, status = 200, err = null where attachment_id = p_id returning * into u;
  if u.person_id is not null then
    insert into public.media_answers (event_id, person_id, answer, files) values (u.event_id, u.person_id, 'uploaded', 1)
      on conflict (event_id, person_id) do update set answer = 'uploaded', files = public.media_answers.files + 1, at = now();
  end if;
end $$;

revoke all on function public.media_copy_jobs(text, int), public.media_copy_token(text, uuid, text), public.media_copy_folder(text, uuid, uuid, text),
  public.media_copy_result(text, text, text, text) from public, anon, authenticated;
grant execute on function public.media_copy_jobs(text, int), public.media_copy_token(text, uuid, text), public.media_copy_folder(text, uuid, uuid, text),
  public.media_copy_result(text, text, text, text) to service_role;

-- Wake the copy function when something is waiting (async, so the runner never waits on big files).
create or replace function public.media_kick_copy() returns int
language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  if not exists (select 1 from public.media_uploads where dest = 'gdrive' and copied_at is null and tries < 5) then return 0; end if;
  select value into s from public.app_keys where name = 'media_copy_secret';
  perform net.http_post('https://fwptdvoifkfljblyziva.supabase.co/functions/v1/busters-media-copy',
    jsonb_build_object('secret', s), headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 5000);
  return 1;
end $$;
revoke all on function public.media_kick_copy() from public, anon, authenticated;

-- ---------- Runner ----------
-- Photo calls need the upload link, so Dropbox stays connected either way. With Drive, also scan and copy.

create or replace function public.media_run() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  n := n + public.media_harvest();
  n := n + public.media_scan_dropbox();
  perform public.media_kick_copy();
  for r in select e.id from public.events e
           join public.crew_media m on m.crew_id = e.crew_id and m.refresh_token is not null and (m.dest = 'dropbox' or m.g_refresh_token is not null)
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

-- ---------- What the app shows ----------

drop function if exists public.media_status(uuid);
create or replace function public.media_status(p_crew uuid) returns json
language plpgsql stable security definer set search_path = '' as $$
declare m public.crew_media; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if not public.can(p_crew, 'webmaster') then raise exception 'not allowed'; end if;
  select * into m from public.crew_media where crew_id = p_crew;
  return json_build_object(
    'has_app', m.app_key is not null, 'connected', m.refresh_token is not null, 'account', m.account_name, 'email', m.account_email,
    'root', coalesce(m.root_folder, '/LAGB Event Media'), 'connected_at', m.connected_at, 'is_admin', public.can(p_crew, 'crew_admin'),
    'dest', coalesce(m.dest, 'dropbox'),
    'google', json_build_object('has_app', exists (select 1 from public.app_keys where name = 'google_client_id'),
      'connected', m.g_refresh_token is not null, 'email', m.g_email, 'root', coalesce(m.g_root_name, 'Busters Photo Drop'),
      'root_id', m.g_root_id, 'link_open', m.g_link_token is not null and m.g_link_expires > now(), 'link_expires', m.g_link_expires),
    'queue', json_build_object(
      'waiting', (select count(*) from public.media_uploads u where u.crew_id = p_crew and u.dest = 'gdrive' and u.copied_at is null and u.tries < 5),
      'failed', (select count(*) from public.media_uploads u where u.crew_id = p_crew and u.dest = 'gdrive' and u.copied_at is null and u.tries >= 5),
      'copied', (select count(*) from public.media_uploads u where u.crew_id = p_crew and u.dest = 'gdrive' and u.copied_at is not null)),
    'events', (select coalesce(json_agg(x order by x.event_date desc), '[]') from (
      select e.id, e.title, e.event_date, em.called_at, em.completed_at, em.request_url, em.folder_path, em.g_folder_id,
        (select count(*) from public.event_workers(e.id)) as went,
        (select count(*) from public.media_answers ma where ma.event_id = e.id and ma.person_id in (select public.event_workers(e.id))) as answered,
        (select coalesce(sum(files), 0) from public.media_answers ma where ma.event_id = e.id) as files
      from public.events e left join public.event_media em on em.event_id = e.id
      where e.crew_id = p_crew and e.status in ('scheduled', 'closed') and coalesce(e.end_date, e.event_date) < today
        and e.event_date > today - 90 and exists (select 1 from public.event_workers(e.id))) x));
end $$;
revoke all on function public.media_status(uuid) from public, anon;
grant execute on function public.media_status(uuid) to authenticated;
