-- Chat in Busters, backed by Discord. The Chat tab shows the crew channel (#rookies) and each event's Discord thread.
-- Reading and sending go through the busters-chat edge function, which uses the bot token for reading and a
-- channel webhook for sending, so app messages show in Discord under the member's own name and picture.

-- The webhook Busters posts through (made on first send in the crew channel; secrets stay in the database).
alter table public.crew_discord add column if not exists chat_webhook_id text;
alter table public.crew_discord add column if not exists chat_webhook_token text;

-- Messages sent from the app: which member wrote each one (Discord only knows the webhook).
create table if not exists public.chat_sent (
  message_id text primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  person_id uuid references public.people(id) on delete set null,
  channel_id text not null,
  created_at timestamptz not null default now()
);
alter table public.chat_sent enable row level security;

-- How far each member has read in each chat (a Discord message id), for unread dots.
create table if not exists public.chat_reads (
  user_id uuid not null references auth.users(id) on delete cascade,
  channel_id text not null,
  last_read text not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, channel_id)
);
alter table public.chat_reads enable row level security;
drop policy if exists chat_reads_own on public.chat_reads;
create policy chat_reads_own on public.chat_reads for select using (user_id = (select auth.uid()));

-- Which of the crew's events have a Discord thread, so event pages can show a Chat button.
create or replace function public.chat_events(p_crew uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select t.event_id from public.discord_threads t
  where t.crew_id = p_crew
    and exists (select 1 from public.people p where p.crew_id = p_crew and p.user_id = (select auth.uid()) and p.status in ('active', 'rookie'));
$$;
revoke all on function public.chat_events(uuid) from public, anon;
grant execute on function public.chat_events(uuid) to authenticated;

-- Photo drop: photos posted from the app arrive as webhook (bot) messages. Keep skipping other bots, but take
-- these, credited to the member who sent them.
do $$
declare d text := pg_get_functiondef('public.media_harvest()'::regprocedure);
begin
  if position('chat_sent' in d) = 0 then
    d := replace(d,
      $x$continue when coalesce((msg->'author'->>'bot')::boolean, false);$x$,
      $x$continue when coalesce((msg->'author'->>'bot')::boolean, false) and not exists (select 1 from public.chat_sent cs where cs.message_id = msg->>'id');$x$);
    d := replace(d,
      $x$select pp.person_id into pid from public.people_private pp where pp.crew_id = em.crew_id and pp.discord_user_id = msg->'author'->>'id';$x$,
      $x$select pp.person_id into pid from public.people_private pp where pp.crew_id = em.crew_id and pp.discord_user_id = msg->'author'->>'id';
        if pid is null then select cs.person_id into pid from public.chat_sent cs where cs.message_id = msg->>'id'; end if;$x$);
    if position('cs.message_id = msg' in d) = 0 or position('cs.person_id into pid' in d) = 0 then raise exception 'media_harvest did not match the expected text'; end if;
    execute d;
  end if;
end $$;
