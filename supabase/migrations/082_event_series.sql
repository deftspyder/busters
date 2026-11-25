-- 082: multi-day events. Each day is its own event ("Creepy I.E. - Day 1", "- Day 2") with its own sign-ups,
-- and the days share events.series. Attendance counts a series once per person, however many days they went
-- (Bill, Nov 25: a multi-day event is one event attended).

alter table public.events add column if not exists series text;
comment on column public.events.series is 'Shared by the days of one multi-day event. Attendance counts a series once per person.';
create index if not exists events_series_idx on public.events (crew_id, series) where series is not null;

-- The app reads events through this view: same columns as before, with series added at the end.
create or replace view public.events_full with (security_invoker = true) as
 select e.id, e.crew_id, e.title, e.category, e.status, e.event_date, e.end_date, e.call_time, e.start_time, e.wrap_time,
    e.schedule, e.parking, e.conditions, e.notes, e.contact_name, e.contact_phone, e.contact_email, e.poc_id,
    e.min_busters, e.goal_busters, e.max_busters, e.source, e.source_key, e.proposed_by, e.created_by, e.created_at,
    e.updated_at, e.updated_by, e.lagb_contact, e.sheet_attendees, e.sheet_reserve,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going')::integer as going,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'maybe')::integer as maybe,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going' and r.spot = 'in')::integer as spots_in,
    public.event_missing(e.*) as missing,
    e.raised, e.hosted, e.host_id, e.host_share, e.credit_published, e.date_tbd, e.details_ok,
    public.event_missing_all(e.*) as missing_all,
    e.extra_times,
    e.series
   from public.events e;

-- The two functions below are patched in place from their live definitions, so nothing else in them changes.
-- Each patch checks that the text it expects is there and stops the whole migration if it is not.
do $$
declare d text; n text;
begin
  -- bridge_sheet: keep the series the bridge sends for each day of a multi-day tab.
  d := pg_get_functiondef('public.bridge_sheet(text, jsonb)'::regprocedure);
  n := replace(d, 'source, source_key, date_tbd)', 'source, source_key, date_tbd, series)');
  if n = d then raise exception 'bridge_sheet: insert column list not found'; end if; d := n;
  n := replace(d, $q$'sheet', t->>'tab', coalesce((t->>'tbd')::boolean, false))$q$,
                  $q$'sheet', t->>'tab', coalesce((t->>'tbd')::boolean, false), nullif(t->>'series',''))$q$);
  if n = d then raise exception 'bridge_sheet: insert values not found'; end if; d := n;
  n := replace(d, 'perform public.sheet_fill(e.id, t);',
    $q$if nullif(t->>'series','') is not null and e.series is distinct from t->>'series' then
      update public.events set series = t->>'series' where id = e.id;
    end if;
    perform public.sheet_fill(e.id, t);$q$);
  if n = d then raise exception 'bridge_sheet: sheet_fill call not found'; end if;
  execute n;

  -- personnel_roster: events done and events this year count a series once.
  d := pg_get_functiondef('public.personnel_roster(uuid)'::regprocedure);
  n := replace(d, '(select count(*) from public.rsvps r join public.events e on e.id = r.event_id',
                  '(select count(distinct coalesce(e.series, e.id::text)) from public.rsvps r join public.events e on e.id = r.event_id');
  if n = d or (length(n) - length(d)) <> 2 * (length('count(distinct coalesce(e.series, e.id::text))') - length('count(*)')) then
    raise exception 'personnel_roster: expected two counts to patch';
  end if;
  execute n;
end $$;
