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

-- Thread intro: just the title, date and main place (no details card).
create or replace function public.dc_ensure_thread(p_event uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare e public.events; d public.crew_discord; t text; r jsonb; who text; ids jsonb; place text;
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
  select coalesce(nullif(pl.name, ''), pl.address) into place
    from public.event_places ep join public.places pl on pl.id = ep.place_id where ep.event_id = p_event order by ep.sort limit 1;
  select string_agg('<@' || pp.discord_user_id || '>', ' '), coalesce(jsonb_agg(pp.discord_user_id), '[]')
    into who, ids
    from public.event_workers(p_event) w join public.people_private pp on pp.person_id = w
    where pp.discord_user_id is not null;
  perform public.dc_http(e.crew_id, 'POST', '/channels/' || t || '/messages', jsonb_build_object(
    'content', 'This is the event thread for **' || e.title || '**' || E'\n'
      || '📅 ' || public.dc_day(e.event_date) || coalesce(E'\n' || '📍 ' || place, '') || E'\n\n'
      || 'Use it to ask questions and coordinate, and post your photos here after the event to be automatically uploaded to LAGB Media Ops.'
      || case when who is not null then E'\n\n' || 'Signed up: ' || who else '' end,
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array(), 'users', ids)));
  insert into public.discord_thread_members (event_id, discord_user_id)
    select p_event, x from jsonb_array_elements_text(ids) x on conflict do nothing;
  return t;
end $$;
revoke all on function public.dc_ensure_thread(uuid) from public, anon, authenticated;
