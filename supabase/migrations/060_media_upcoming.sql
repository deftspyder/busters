-- Admin, then Media also lists upcoming events, with when each one's Discord thread and Drive folder will be made.
-- A thread is made with the event's first Discord card (dc_next says when that is), and its folder follows within
-- about 15 minutes. Date TBD events get neither until a date is set.

create or replace function public.media_status(p_crew uuid) returns json
language plpgsql stable security definer set search_path to '' as $$
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
        and e.event_date > today - 90 and exists (select 1 from public.event_workers(e.id))) x),
    'upcoming', (select coalesce(json_agg(x order by x.event_date, x.title), '[]') from (
      select e.id, e.title, e.event_date, e.date_tbd,
        exists (select 1 from public.discord_threads t where t.event_id = e.id) as has_thread,
        em.g_folder_id is not null as has_folder,
        nx.due_at as thread_due
      from public.events e
        left join public.event_media em on em.event_id = e.id
        left join lateral public.dc_next(e.id) nx on true
      where e.crew_id = p_crew and e.status = 'scheduled' and coalesce(e.end_date, e.event_date) >= today) x));
end $$;
