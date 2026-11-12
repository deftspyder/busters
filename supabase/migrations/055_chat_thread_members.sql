-- Chat: an event chat also shows for anyone who is in that event's Discord thread (joined it themselves, posted in
-- it, or was added by Busters), not just for people who said Going or Maybe. Every 15 minutes a job reads the
-- member list of each recent or upcoming event thread from Discord and records it here.

create table if not exists public.discord_thread_present (
  event_id uuid not null references public.events(id) on delete cascade,
  discord_user_id text not null,
  seen_at timestamptz not null default now(),
  primary key (event_id, discord_user_id)
);
alter table public.discord_thread_present enable row level security;

create or replace function public.chat_sync_members() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare t record; r jsonb; n int := 0;
begin
  for t in
    select dt.event_id, dt.crew_id, dt.thread_id from public.discord_threads dt
    join public.events e on e.id = dt.event_id
    where e.status <> 'cancelled' and coalesce(e.end_date, e.event_date) >= current_date - 14
  loop
    r := public.dc_http_json(t.crew_id, 'GET', '/channels/' || t.thread_id || '/thread-members?limit=100', null);
    continue when r is null or (r->>'status')::int <> 200 or jsonb_typeof(r->'body') <> 'array';
    delete from public.discord_thread_present where event_id = t.event_id;
    insert into public.discord_thread_present (event_id, discord_user_id)
      select t.event_id, m->>'user_id' from jsonb_array_elements(r->'body') m where m->>'user_id' is not null
      on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.chat_sync_members() from public, anon, authenticated;

-- Runs a few minutes after the main Discord job so they don't overlap.
select cron.unschedule(jobid) from cron.job where jobname = 'chat-members';
select cron.schedule('chat-members', '9,24,39,54 * * * *', $$select public.chat_sync_members()$$);

-- Event chats for the Chat tab: every event with a thread, and whether the signed-in member is in that thread.
drop function if exists public.chat_events(uuid);
create function public.chat_events(p_crew uuid) returns table (event_id uuid, joined boolean)
language sql stable security definer set search_path = public as $$
  select t.event_id,
         exists (select 1 from public.discord_thread_present x
                 join public.people_private pp on pp.discord_user_id = x.discord_user_id and pp.crew_id = p_crew
                 join public.people me on me.id = pp.person_id and me.user_id = (select auth.uid())
                 where x.event_id = t.event_id)
  from public.discord_threads t
  where t.crew_id = p_crew
    and exists (select 1 from public.people p where p.crew_id = p_crew and p.user_id = (select auth.uid()) and p.status in ('active', 'rookie'));
$$;
revoke all on function public.chat_events(uuid) from public, anon;
grant execute on function public.chat_events(uuid) to authenticated;
