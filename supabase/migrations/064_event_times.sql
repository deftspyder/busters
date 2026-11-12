-- Event times: Start and Wrap are the standard pair; Call and any other times (Meet-up, Photo op, Break, or a named
-- one) are added only when the event has them, and the editor and event page list them in time order. Call time is
-- no longer counted as a missing detail.

alter table public.events add column if not exists extra_times jsonb not null default '[]'::jsonb;

create or replace function public.event_missing_all(e public.events) returns text[]
language sql stable set search_path to '' as $$
  select array_remove(array[
    case when e.date_tbd then 'Date' end,
    case when e.poc_id is null then 'Point of contact' end,
    case when coalesce(e.contact_name, '') = '' or (coalesce(e.contact_phone, '') = '' and coalesce(e.contact_email, '') = '') then 'Event contact' end,
    case when not exists (select 1 from public.event_places ep join public.places pl on pl.id = ep.place_id
                          where ep.event_id = e.id and (coalesce(pl.address, '') <> '' or pl.lat is not null)) then 'Address' end,
    case when e.start_time is null then 'Start time' end,
    case when e.wrap_time is null then 'Wrap time' end,
    case when e.min_busters is null then 'Minimum Busters' end,
    case when e.goal_busters is null then 'Goal' end
  ], null);
$$;

create or replace view public.events_full with (security_invoker = true) as
 SELECT id, crew_id, title, category, status, event_date, end_date, call_time, start_time, wrap_time, schedule, parking, conditions, notes,
    contact_name, contact_phone, contact_email, poc_id, min_busters, goal_busters, max_busters, source, source_key, proposed_by,
    created_by, created_at, updated_at, updated_by, lagb_contact, sheet_attendees, sheet_reserve,
    ((SELECT count(*) FROM public.rsvps r WHERE r.event_id = e.id AND r.answer = 'going'))::integer AS going,
    ((SELECT count(*) FROM public.rsvps r WHERE r.event_id = e.id AND r.answer = 'maybe'))::integer AS maybe,
    ((SELECT count(*) FROM public.rsvps r WHERE r.event_id = e.id AND r.answer = 'going' AND r.spot = 'in'))::integer AS spots_in,
    public.event_missing(e.*) AS missing,
    raised, hosted, host_id, host_share, credit_published,
    date_tbd,
    details_ok, public.event_missing_all(e.*) AS missing_all,
    extra_times
   FROM public.events e;

-- Editor: save_event stores the extra times ([{label, time}], time as HH:MM).
do $$
declare d text := pg_get_functiondef('public.save_event(uuid,jsonb)'::regprocedure);
  f text := $x$wrap_time = case when p ? 'wrap_time' then nullif(p->>'wrap_time','')::time else wrap_time end,$x$;
begin
  if position('extra_times =' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'save_event: wrap_time line not found once'; end if;
  execute replace(d, f, f || $x$
    extra_times = case when p ? 'extra_times' and jsonb_typeof(p->'extra_times') = 'array' then p->'extra_times' else extra_times end,$x$);
end $$;
