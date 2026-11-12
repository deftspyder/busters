-- Minimum and Goal (how many Busters an event needs) are optional: LAGB has never tracked them, so they no longer
-- count as missing details. Short-staffed alerts and bumps still run for events that have a minimum set.
-- Later: suggest them from past attendance once there is history (roadmap).

create or replace function public.event_missing_all(e public.events) returns text[]
language sql stable set search_path to '' as $$
  select array_remove(array[
    case when e.date_tbd then 'Date' end,
    case when e.poc_id is null then 'Point of contact' end,
    case when coalesce(e.contact_name, '') = '' or (coalesce(e.contact_phone, '') = '' and coalesce(e.contact_email, '') = '') then 'Event contact' end,
    case when not exists (select 1 from public.event_places ep join public.places pl on pl.id = ep.place_id
                          where ep.event_id = e.id and (coalesce(pl.address, '') <> '' or pl.lat is not null)) then 'Address' end,
    case when e.start_time is null then 'Start time' end,
    case when e.wrap_time is null then 'Wrap time' end
  ], null);
$$;
