-- Webmasters and crew admins (LAGB: Jeff and Bill) are quietly added to every event thread, so each one shows in
-- their sidebar: upcoming events plus anything from the last 45 days (the photo window). Going members are still
-- added for upcoming events only.

create or replace function public.dc_thread_sync() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; st int; today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  for r in
    with th as (
      select t.event_id, t.crew_id, t.thread_id, coalesce(e.end_date, e.event_date) as last_day, e.status
      from public.discord_threads t join public.events e on e.id = t.event_id
        join public.crew_discord d on d.crew_id = t.crew_id and d.bot_token is not null
      where e.status in ('scheduled', 'closed') and coalesce(e.end_date, e.event_date) >= today - 45),
    want as (
      select th.event_id, th.crew_id, th.thread_id, pp.discord_user_id
      from th cross join lateral public.event_workers(th.event_id) w
        join public.people_private pp on pp.person_id = w and pp.discord_user_id is not null
      where th.status = 'scheduled' and th.last_day >= today
      union
      select th.event_id, th.crew_id, th.thread_id, pp.discord_user_id
      from th join public.people p on p.crew_id = th.crew_id and p.status in ('active', 'rookie')
          and p.abilities && array['webmaster', 'crew_admin']
        join public.people_private pp on pp.person_id = p.id and pp.discord_user_id is not null)
    select * from want w
    where not exists (select 1 from public.discord_thread_members m where m.event_id = w.event_id and m.discord_user_id = w.discord_user_id)
    limit 20 loop
    st := public.dc_http(r.crew_id, 'PUT', '/channels/' || r.thread_id || '/thread-members/' || r.discord_user_id, null);
    if st between 200 and 299 then
      insert into public.discord_thread_members (event_id, discord_user_id) values (r.event_id, r.discord_user_id) on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.dc_thread_sync() from public, anon, authenticated;
