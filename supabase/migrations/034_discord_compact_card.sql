-- Compact Discord event card in Busters' own layout:
--   [Busters icon] <why it's posted> · Are you in?
--   **Event title**
--   Sun, Nov 29 · Call 3 PM · 6 to 11 PM · Hollywood Blvd
--   Need 8 · **Going 3** · Maybe 2
-- Buttons: Going / Maybe / Can't, then Navigate (opens maps) and Details (private reply with the fuller info).

create or replace function public.dc_t(t time) returns text
language sql immutable set search_path = '' as $$
  select replace(to_char(t, 'FMHH12:MI AM'), ':00', '');
$$;

create or replace function public.dc_trange(s time, w time) returns text
language sql immutable set search_path = '' as $$
  select case when w is null then public.dc_t(s)
              when (s < '12:00') = (w < '12:00') then regexp_replace(public.dc_t(s), ' (AM|PM)$', '') || ' to ' || public.dc_t(w)
              else public.dc_t(s) || ' to ' || public.dc_t(w) end;
$$;

create or replace function public.dc_embed(p_event uuid, p_kind text, p_extra text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare e public.events_full; pl record; f jsonb := '[]'::jsonb; crew text; head text; color int; descr text;
  whenl text; counts text; need int;
begin
  select * into e from public.events_full where id = p_event;
  select c.short_name into crew from public.crews c where c.id = e.crew_id;
  select p.name, p.address, ep.label into pl from public.event_places ep join public.places p on p.id = ep.place_id
    where ep.event_id = p_event order by (coalesce(ep.label, 'Event') = 'Event') desc, ep.sort limit 1;
  color := case p_kind when 'short' then 15774258 when 'cancelled' then 8421504 when 'backon' then 5763719
    when 'photos' then 3908599 when 'lastcall' then 16753920 when 'remind' then 3447003 else 3519208 end;

  if p_kind = 'photos' then
    return jsonb_strip_nulls(jsonb_build_object('color', color, 'author', jsonb_build_object('name', '📷 Photo call'),
      'title', left(e.title, 250), 'description', 'Were you there? Reply here with your photos and videos.' || coalesce(E'\n\n' || p_extra, ''),
      'footer', jsonb_build_object('text', coalesce(crew, '') || ' · Busters')));
  end if;

  head := case p_kind when 'new' then '🆕 New event' when 'remind' then '⏰ Coming up' when 'lastcall' then '📣 Last call'
    when 'short' then '🚨 Short on Busters' when 'changes' then '✏️ Updated' when 'backon' then '✅ Back on'
    when 'cancelled' then '❌ Cancelled' else null end;
  if p_kind <> 'cancelled' then head := coalesce(head || ' · ', '') || case when p_kind = 'short' then 'Can you make it?' else 'Are you in?' end; end if;

  whenl := public.dc_day(e.event_date)
    || case when e.end_date is not null and e.end_date <> e.event_date then ' to ' || public.dc_day(e.end_date) else '' end
    || coalesce(' · Call ' || public.dc_t(e.call_time), '')
    || coalesce(' · ' || public.dc_trange(e.start_time, e.wrap_time), '')
    || case when e.call_time is null and e.start_time is null then ' · Times coming' else '' end
    || coalesce(' · ' || pl.name, '');

  need := coalesce(e.goal_busters, e.min_busters);
  if p_kind = 'cancelled' then counts := null;
  elsif e.max_busters is not null then
    counts := e.max_busters || ' spots · **Want in ' || e.going || '** · Maybe ' || coalesce(e.maybe, 0);
  else
    counts := coalesce('Need ' || need || ' · ', '') || '**Going ' || e.going || '** · Maybe ' || coalesce(e.maybe, 0)
      || case when e.min_busters is not null and e.going < e.min_busters then ' · **' || (e.min_busters - e.going) || ' more needed**' else '' end;
  end if;

  descr := whenl || coalesce(E'\n' || counts, '')
    || case when p_kind in ('manual', 'new', 'remind', 'lastcall', 'short') and p_extra is not null then E'\n\n' || p_extra else '' end;
  if p_kind in ('changes', 'backon') and p_extra is not null then
    f := f || jsonb_build_object('name', 'What changed', 'value', left(p_extra, 1000), 'inline', false);
  end if;

  return jsonb_strip_nulls(jsonb_build_object('color', color,
    'author', jsonb_build_object('name', head, 'icon_url', 'https://deftspyder.github.io/busters/icons/icon-192.png'),
    'title', left(e.title, 250), 'description', left(descr, 4000),
    'fields', case when jsonb_array_length(f) > 0 then f end,
    'footer', jsonb_build_object('text', coalesce(crew, '') || ' · Busters')));
end $$;

-- Buttons: answers on the first row, Navigate and Details on the second.
create or replace function public.dc_buttons(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare addr text; row2 jsonb := '[]'::jsonb;
begin
  select coalesce(p.address, p.name) into addr from public.event_places ep join public.places p on p.id = ep.place_id
    where ep.event_id = p_event order by (coalesce(ep.label, 'Event') = 'Event') desc, ep.sort limit 1;
  if addr is not null then
    row2 := row2 || jsonb_build_object('type', 2, 'style', 5, 'label', 'Navigate', 'emoji', jsonb_build_object('name', '🧭'),
      'url', 'https://www.google.com/maps/search/?api=1&query=' || replace(replace(replace(replace(replace(replace(addr, '%', '%25'), '+', '%2B'), '&', '%26'), '?', '%3F'), '#', '%23'), ' ', '+'));
  end if;
  row2 := row2 || jsonb_build_object('type', 2, 'style', 2, 'label', 'Details', 'emoji', jsonb_build_object('name', 'ℹ️'), 'custom_id', 'details:' || p_event);
  return jsonb_build_array(
    jsonb_build_object('type', 1, 'components', jsonb_build_array(
      jsonb_build_object('type', 2, 'style', 3, 'label', 'Going', 'emoji', jsonb_build_object('name', '✅'), 'custom_id', 'rsvp:' || p_event || ':going'),
      jsonb_build_object('type', 2, 'style', 2, 'label', 'Maybe', 'custom_id', 'rsvp:' || p_event || ':maybe'),
      jsonb_build_object('type', 2, 'style', 4, 'label', 'Can''t', 'custom_id', 'rsvp:' || p_event || ':no'))),
    jsonb_build_object('type', 1, 'components', row2));
end $$;

-- What Details shows (privately, to whoever taps it): public event details only, never contact info.
create or replace function public.discord_details(p_app text, p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c uuid; e public.events_full; places text; f jsonb := '[]'::jsonb; t text;
begin
  select crew_id into c from public.crew_discord where app_id = p_app;
  select * into e from public.events_full where id = p_event and crew_id = c;
  if e.id is null then return null; end if;
  t := public.dc_day(e.event_date) || case when e.end_date is not null and e.end_date <> e.event_date then ' to ' || public.dc_day(e.end_date) else '' end
    || coalesce(E'\nCall ' || public.dc_t(e.call_time), '')
    || coalesce(E'\nStart ' || public.dc_t(e.start_time) || coalesce(', wrap ' || public.dc_t(e.wrap_time), ''), '');
  f := f || jsonb_build_object('name', 'When', 'value', t);
  select string_agg('**' || coalesce(ep.label, 'Event') || ':** ' || p.name || coalesce(E'\n' || p.address, ''), E'\n' order by ep.sort)
    into places from public.event_places ep join public.places p on p.id = ep.place_id where ep.event_id = p_event;
  if places is not null then f := f || jsonb_build_object('name', 'Where', 'value', left(places, 1000)); end if;
  if nullif(trim(e.parking), '') is not null then f := f || jsonb_build_object('name', 'Driving and parking', 'value', left(e.parking, 1000)); end if;
  if nullif(trim(e.schedule), '') is not null then f := f || jsonb_build_object('name', 'Schedule', 'value', left(e.schedule, 1000)); end if;
  if nullif(trim(e.conditions), '') is not null then f := f || jsonb_build_object('name', 'Conditions', 'value', left(e.conditions, 1000)); end if;
  if nullif(trim(e.notes), '') is not null then f := f || jsonb_build_object('name', 'Notes', 'value', left(e.notes, 1000)); end if;
  f := f || jsonb_build_object('name', 'Busters', 'value', public.dc_count(e.going, e.min_busters));
  return jsonb_build_object('color', 3519208, 'title', left(e.title, 250), 'fields', f);
end $$;
revoke all on function public.discord_details(text, uuid) from public, anon, authenticated;
