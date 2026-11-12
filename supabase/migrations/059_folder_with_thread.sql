-- Each event's Drive folder is made as soon as its Discord thread exists, not when the first photo arrives, so
-- Busters Photo Drop always mirrors the event threads and an empty folder never looks like something went wrong.
-- busters-media-copy makes the folders; the 15-minute run wakes it when any are missing.

-- Events with a thread but no Drive folder yet (crews whose photos go to Google Drive).
create or replace function public.media_copy_folders_needed(p_secret text) returns jsonb
language plpgsql security definer set search_path to '' as $$
begin
  if p_secret is distinct from (select value from public.app_keys where name = 'media_copy_secret') then raise exception 'not allowed'; end if;
  return (select coalesce(jsonb_agg(x), '[]') from (
    select t.crew_id, t.event_id, m.g_root_id, m.g_root_name,
           to_char(e.event_date, 'YYYY-MM-DD') || ' ' || left(btrim(regexp_replace(e.title, '[\\/:*?"<>|]+', ' ', 'g')), 80) as folder_name
    from public.discord_threads t
    join public.events e on e.id = t.event_id
    join public.crew_media m on m.crew_id = t.crew_id
    left join public.event_media em on em.event_id = t.event_id
    where m.dest = 'gdrive' and m.g_refresh_token is not null
      and e.status <> 'cancelled' and not e.date_tbd and em.g_folder_id is null
    order by e.event_date limit 20) x);
end $$;
revoke all on function public.media_copy_folders_needed(text) from public, anon, authenticated;

-- Saving an event's folder makes its event_media row if the photo call hasn't made it yet.
create or replace function public.media_copy_folder(p_secret text, p_crew uuid, p_event uuid, p_folder text) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if p_secret is distinct from (select value from public.app_keys where name = 'media_copy_secret') then raise exception 'not allowed'; end if;
  if p_event is null then update public.crew_media set g_root_id = p_folder where crew_id = p_crew;
  else
    insert into public.event_media (event_id, crew_id, g_folder_id) values (p_event, p_crew, p_folder)
      on conflict (event_id) do update set g_folder_id = excluded.g_folder_id;
  end if;
end $$;

-- Wake the copier when there are files to copy or folders to make.
create or replace function public.media_kick_copy() returns integer
language plpgsql security definer set search_path to '' as $$
declare s text;
begin
  if not exists (select 1 from public.media_uploads where dest = 'gdrive' and copied_at is null and tries < 5)
     and not exists (select 1 from public.discord_threads t join public.events e on e.id = t.event_id
                     join public.crew_media m on m.crew_id = t.crew_id left join public.event_media em on em.event_id = t.event_id
                     where m.dest = 'gdrive' and m.g_refresh_token is not null and e.status <> 'cancelled' and not e.date_tbd and em.g_folder_id is null)
  then return 0; end if;
  select value into s from public.app_keys where name = 'media_copy_secret';
  perform net.http_post('https://fwptdvoifkfljblyziva.supabase.co/functions/v1/busters-media-copy',
    jsonb_build_object('secret', s), headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 5000);
  return 1;
end $$;
