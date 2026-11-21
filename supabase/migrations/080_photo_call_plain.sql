-- Photo call as a plain message, no card. Lead with the ask, tags at the end.
-- The thread already names the event and everyone tagged was there, so no title or date.
-- Mark complete / reopen edits the same message (embeds cleared so older card-style calls convert too).

create or replace function public.media_call_payload(p_event uuid, p_done boolean) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.events; em public.event_media; who text; ids jsonb; crew text; btns jsonb; body text;
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
  if p_done then
    body := '📷 **Photos collected, thanks everyone!**' || E'\n' ||
            'Still got a great shot? Post it here or tap **Upload photos**.';
  else
    body := '📷 **Please post your photos and videos from this event, or let us know you don''t have any.**' || E'\n' ||
            'Post them right here in this thread and they''ll go straight to the ' || coalesce(crew || ' ', '') || 'media team for the website.' || E'\n' ||
            'Files over 10 MB: tap **Upload photos** below instead.' || E'\n' ||
            'No photos? Tap **No photos from me** and we''ll stop asking.' ||
            coalesce(E'\n\n' || who, '');
  end if;
  return jsonb_build_object(
    'content', body,
    'embeds', '[]'::jsonb,
    'components', jsonb_build_array(jsonb_build_object('type', 1, 'components', btns)),
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array(), 'users', case when p_done then '[]'::jsonb else ids end));
end $$;
revoke all on function public.media_call_payload(uuid, boolean) from public, anon, authenticated;

-- Mark complete / reopen: send the whole payload now that the text lives in content (edits never ping).
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
      public.media_call_payload(p_event, p_done));
  end if;
  perform public.log_action(e.crew_id, 'media_complete', 'event', p_event, case when p_done then 'Marked photos complete for ' else 'Reopened photos for ' end || e.title);
end $$;

-- Reminder: same shape, ask first, tags last.
create or replace function public.media_send_reminder(p_event uuid) returns integer
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
    'content', '📷 **Reminder: please post your photos and videos from this event, or let us know you don''t have any.**' || E'\n' ||
               'Files over 10 MB: tap **Upload photos** on the pinned message. No photos? Tap **No photos from me** there and we''ll stop asking.' ||
               E'\n\n' || who,
    'message_reference', jsonb_build_object('message_id', em.call_message_id, 'fail_if_not_exists', false),
    'allowed_mentions', jsonb_build_object('parse', jsonb_build_array(), 'users', ids)));
  update public.event_media set reminded_at = now() where event_id = p_event;
  return st;
end $$;
