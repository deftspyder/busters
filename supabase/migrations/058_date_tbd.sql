-- Events whose month is known but not the day ("12/XX" tabs on the sheet). They show in the Events list under their
-- month as "Date TBD" and count as needing details (Date), but nothing automatic runs for them until a date is set:
-- no Discord card, thread, Events-tab entry, reminders, DMs, change posts, alerts, photo calls or Google Calendar entry.
-- event_date holds the 1st of the month while date_tbd is on.

alter table public.events add column if not exists date_tbd boolean not null default false;

-- events_full gains date_tbd (appended, so the view can be replaced in place).
create or replace view public.events_full with (security_invoker = true) as
 SELECT id, crew_id, title, category, status, event_date, end_date, call_time, start_time, wrap_time, schedule, parking, conditions, notes,
    contact_name, contact_phone, contact_email, poc_id, min_busters, goal_busters, max_busters, source, source_key, proposed_by,
    created_by, created_at, updated_at, updated_by, lagb_contact, sheet_attendees, sheet_reserve,
    ((SELECT count(*) FROM public.rsvps r WHERE r.event_id = e.id AND r.answer = 'going'))::integer AS going,
    ((SELECT count(*) FROM public.rsvps r WHERE r.event_id = e.id AND r.answer = 'maybe'))::integer AS maybe,
    ((SELECT count(*) FROM public.rsvps r WHERE r.event_id = e.id AND r.answer = 'going' AND r.spot = 'in'))::integer AS spots_in,
    public.event_missing(e.*) AS missing,
    raised, hosted, host_id, host_share, credit_published,
    date_tbd
   FROM public.events e;

-- "Date" leads the missing-details list while the day isn't set.
create or replace function public.event_missing(e public.events) returns text[]
language sql stable set search_path to '' as $$
  select array_remove(array[
    case when e.date_tbd then 'Date' end,
    case when e.poc_id is null then 'Point of contact' end,
    case when coalesce(e.contact_name, '') = '' or (coalesce(e.contact_phone, '') = '' and coalesce(e.contact_email, '') = '') then 'Event contact' end,
    case when not exists (select 1 from public.event_places ep join public.places pl on pl.id = ep.place_id
                          where ep.event_id = e.id and (coalesce(pl.address, '') <> '' or pl.lat is not null)) then 'Address' end,
    case when e.call_time is null then 'Call time' end,
    case when e.start_time is null then 'Start time' end,
    case when e.wrap_time is null then 'Wrap time' end,
    case when e.min_busters is null then 'Minimum Busters' end,
    case when e.goal_busters is null then 'Goal' end
  ], null);
$$;

-- Small text edits to existing functions. Each must match exactly once, or the whole migration stops.
create or replace function pg_temp.patch(p_fn regprocedure, p_from text, p_to text) returns void language plpgsql as $$
declare d text := pg_get_functiondef(p_fn); n int;
begin
  if position(p_to in d) > 0 then return; end if;  -- already applied
  n := (length(d) - length(replace(d, p_from, ''))) / greatest(length(p_from), 1);
  if n <> 1 then raise exception '% : expected 1 match for [%], found %', p_fn, left(p_from, 60), n; end if;
  execute replace(d, p_from, p_to);
end $$;

-- Editor: save_event can set or clear date_tbd.
select pg_temp.patch('public.save_event(uuid,jsonb)',
  $x$event_date = coalesce(nullif(p->>'event_date','')::date, event_date),$x$,
  $x$event_date = coalesce(nullif(p->>'event_date','')::date, event_date), date_tbd = case when p ? 'date_tbd' then coalesce((p->>'date_tbd')::boolean, false) else date_tbd end,$x$);

-- Sheet bridge: take "12/XX" tabs (sent with tbd:true and the 1st of the month), and when a tab later gets a real
-- date, move the same event (same month, matching title) onto it so sign-ups carry over.
select pg_temp.patch('public.bridge_sheet(text,jsonb)',
  $x$continue when nullif(t->>'date','') is null or (t->>'date')::date < today;$x$,
  $x$continue when nullif(t->>'date','') is null or (t->>'date')::date < case when coalesce((t->>'tbd')::boolean, false) then date_trunc('month', today)::date else today end;$x$);
select pg_temp.patch('public.bridge_sheet(text,jsonb)',
  $x$    if e.id is null then
      select * into e from public.events where crew_id = c and event_date = (t->>'date')::date$x$,
  $x$    if e.id is null and not coalesce((t->>'tbd')::boolean, false) then
      select * into e from public.events where crew_id = c and date_tbd and status <> 'cancelled'
        and date_trunc('month', event_date) = date_trunc('month', (t->>'date')::date) and public.same_event(title, t->>'title') order by created_at limit 1;
      if e.id is not null then
        update public.events set event_date = (t->>'date')::date, date_tbd = false, source_key = t->>'tab' where id = e.id returning * into e;
        linked := linked || e.title;
      end if;
    end if;
    if e.id is null then
      select * into e from public.events where crew_id = c and event_date = (t->>'date')::date$x$);
select pg_temp.patch('public.bridge_sheet(text,jsonb)',
  $x$contact_name, lagb_contact, source, source_key)$x$,
  $x$contact_name, lagb_contact, source, source_key, date_tbd)$x$);
select pg_temp.patch('public.bridge_sheet(text,jsonb)',
  $x$nullif(t->>'lagb_contact',''), 'sheet', t->>'tab')$x$,
  $x$nullif(t->>'lagb_contact',''), 'sheet', t->>'tab', coalesce((t->>'tbd')::boolean, false))$x$);

-- Nothing automatic for date-TBD events.
select pg_temp.patch('public.alert_plan()', $x$e.status = 'scheduled' and e.min_busters$x$, $x$e.status = 'scheduled' and not e.date_tbd and e.min_busters$x$);
select pg_temp.patch('public.bridge_calendar(text,jsonb)', $x$e2.status in ('scheduled','cancelled')$x$, $x$e2.status in ('scheduled','cancelled') and not e2.date_tbd$x$);
select pg_temp.patch('public.dc_events_changed()', $x$if new.status <> 'scheduled' then return new; end if;$x$, $x$if new.status <> 'scheduled' or new.date_tbd or old.date_tbd then return new; end if;$x$);
select pg_temp.patch('public.dc_next(uuid)', $x$if e.id is null or e.status <> 'scheduled' then return; end if;$x$, $x$if e.id is null or e.status <> 'scheduled' or e.date_tbd then return; end if;$x$);
select pg_temp.patch('public.dc_places_changed()', $x$if e.id is null or e.status <> 'scheduled' or$x$, $x$if e.id is null or e.status <> 'scheduled' or e.date_tbd or$x$);
select pg_temp.patch('public.dc_sched_sync()', $x$(e.id is null or e.status <> 'scheduled' or not d.post_events)$x$, $x$(e.id is null or e.status <> 'scheduled' or e.date_tbd or not d.post_events)$x$);
select pg_temp.patch('public.dc_sched_sync()', $x$e.crew_id = d.crew_id and e.status = 'scheduled' and e.event_date between$x$, $x$e.crew_id = d.crew_id and e.status = 'scheduled' and not e.date_tbd and e.event_date between$x$);
select pg_temp.patch('public.dc_interest_dms()', $x$e.status = 'scheduled' and e.event_date >=$x$, $x$e.status = 'scheduled' and not e.date_tbd and e.event_date >=$x$);
select pg_temp.patch('public.dc_thread_sync()', $x$where e.status in ('scheduled', 'closed') and$x$, $x$where e.status in ('scheduled', 'closed') and not e.date_tbd and$x$);
select pg_temp.patch('public.discord_run()', $x$e.crew_id = d.crew_id and e.status = 'scheduled'$x$, $x$e.crew_id = d.crew_id and e.status = 'scheduled' and not e.date_tbd$x$);
select pg_temp.patch('public.discord_schedule(uuid)', $x$e.crew_id = p_crew and e.status = 'scheduled' and e.event_date between$x$, $x$e.crew_id = p_crew and e.status = 'scheduled' and not e.date_tbd and e.event_date between$x$);
select pg_temp.patch('public.media_run()', $x$where e.status in ('scheduled', 'closed') and$x$, $x$where e.status in ('scheduled', 'closed') and not e.date_tbd and$x$);
