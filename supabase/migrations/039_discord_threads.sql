-- A Discord thread per event, for questions. It's a standalone thread in the channel (not hung off a card),
-- so it survives bumps; every card links to it ("💬 Questions? #thread"). It opens with the event's details,
-- and gets a short note when the event changes or is cancelled. Later the photo call goes in here too.

create table if not exists public.discord_threads (
  event_id uuid primary key references public.events(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  thread_id text not null,
  created_at timestamptz not null default now()
);
alter table public.discord_threads enable row level security;

alter table public.crew_discord add column if not exists post_threads boolean not null default true;

-- Discord call that also returns the reply body.
create or replace function public.dc_http_json(p_crew uuid, p_method text, p_path text, p_body jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare d public.crew_discord; r record;
begin
  select * into d from public.crew_discord where crew_id = p_crew;
  if d.bot_token is null then return null; end if;
  select status, content into r from extensions.http((
    p_method, 'https://discord.com/api/v10' || p_path,
    array[extensions.http_header('Authorization', 'Bot ' || d.bot_token),
          extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
    case when p_body is null then null else 'application/json' end, p_body::text)::extensions.http_request);
  return jsonb_build_object('status', r.status, 'body', case when r.content ~ '^\s*[\{\[]' then r.content::jsonb end);
exception when others then return jsonb_build_object('status', -1);
end $$;
revoke all on function public.dc_http_json(uuid, text, text, jsonb) from public, anon, authenticated;

-- Make sure an event has its thread; returns the thread id (or null if threads are off or Discord said no).
create or replace function public.dc_ensure_thread(p_event uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare e public.events; d public.crew_discord; t text; r jsonb; det jsonb;
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
  perform public.dc_http(e.crew_id, 'POST', '/channels/' || t || '/messages', jsonb_build_object(
    'content', 'Questions about **' || e.title || '**? Ask here. Here are the details:',
    'embeds', case when det is not null then jsonb_build_array(det) else '[]'::jsonb end,
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array())));
  return t;
end $$;
revoke all on function public.dc_ensure_thread(uuid) from public, anon, authenticated;

-- Cards link to the thread, and bumps make sure it exists. Changes and cancellations are noted in the thread.
do $$ declare d text; begin
  d := pg_get_functiondef('public.dc_embed(uuid,text,text)'::regprocedure);
  if position('discord_threads' in d) = 0 then
    d := replace(d, $x$descr := whenl || coalesce(E'\n' || counts, '')$x$,
      $x$descr := whenl || coalesce(E'\n' || counts, '')
    || coalesce(E'\n💬 Questions? <#' || (select t.thread_id from public.discord_threads t where t.event_id = p_event) || '>', '')$x$);
    execute d;
  end if;

  d := pg_get_functiondef('public.dc_bump(uuid,text,text,text)'::regprocedure);
  if position('dc_ensure_thread' in d) = 0 then
    d := replace(d, $x$  if e.id is null then return null; end if;
  select going into g$x$, $x$  if e.id is null then return null; end if;
  if e.status = 'scheduled' and p_kind not in ('cancelled', 'photos') then perform public.dc_ensure_thread(p_event); end if;
  if p_kind in ('changes', 'cancelled', 'backon') and exists (select 1 from public.discord_threads t where t.event_id = p_event) then
    perform public.dc_http(e.crew_id, 'POST', '/channels/' || (select t.thread_id from public.discord_threads t where t.event_id = p_event) || '/messages',
      jsonb_build_object('content', case p_kind when 'cancelled' then '❌ **This event has been cancelled.**'
                                               when 'backon' then '✅ **This event is back on.**' else '✏️ **Event updated**' end
          || coalesce(E'\n' || p_extra, ''), 'allowed_mentions', jsonb_build_object('parse', jsonb_build_array())));
  end if;
  select going into g$x$);
    execute d;
  end if;
end $$;

-- Thread switch on the events team's schedule page.
do $$ declare d text; begin
  d := pg_get_functiondef('public.discord_schedule(uuid)'::regprocedure);
  if position('post_threads' in d) = 0 then
    d := replace(d, $x$'max_posts', coalesce(d.max_posts, 8),$x$, $x$'max_posts', coalesce(d.max_posts, 8), 'post_threads', coalesce(d.post_threads, true),$x$);
    execute d;
  end if;
  d := pg_get_functiondef('public.set_discord_schedule(uuid,jsonb)'::regprocedure);
  if position('post_threads' in d) = 0 then
    d := replace(d, $x$    max_posts = least(20,$x$, $x$    post_threads = coalesce((p->>'post_threads')::boolean, post_threads),
    max_posts = least(20,$x$);
    execute d;
  end if;
end $$;
