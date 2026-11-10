-- Fundraising credit: each event can record money raised. Credit is split evenly among the Busters who
-- worked it, or, for a hosted event, the host gets a set share (10% steps) and the rest is split.
alter table public.events
  add column if not exists raised numeric check (raised is null or raised >= 0),
  add column if not exists hosted boolean not null default false,
  add column if not exists host_id uuid references public.people(id) on delete set null,
  add column if not exists host_share int not null default 90 check (host_share between 0 and 100 and host_share % 10 = 0);

create or replace view public.events_full with (security_invoker = true) as
 select e.id, e.crew_id, e.title, e.category, e.status, e.event_date, e.end_date, e.call_time, e.start_time, e.wrap_time,
    e.schedule, e.parking, e.conditions, e.notes, e.contact_name, e.contact_phone, e.contact_email, e.poc_id,
    e.min_busters, e.goal_busters, e.max_busters, e.source, e.source_key, e.proposed_by, e.created_by, e.created_at,
    e.updated_at, e.updated_by, e.lagb_contact, e.sheet_attendees, e.sheet_reserve,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going')::int as going,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'maybe')::int as maybe,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going' and r.spot = 'in')::int as spots_in,
    public.event_missing(e.*) as missing,
    e.raised, e.hosted, e.host_id, e.host_share
   from public.events e;

-- Who worked an event: Going, and for limited events only those picked In (if anyone was picked).
create or replace function public.event_workers(p_event uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select r.person_id from public.rsvps r join public.events e on e.id = r.event_id
  where r.event_id = p_event and r.answer = 'going'
    and (e.max_busters is null or r.spot = 'in'
         or not exists (select 1 from public.rsvps r2 where r2.event_id = p_event and r2.spot = 'in'));
$$;

-- Credit per person per event.
create or replace function public.fundraising_credit(p_crew uuid, p_year int)
returns table (person_id uuid, event_id uuid, amount numeric)
language sql stable security definer set search_path = '' as $$
  with ev as (
    select e.* from public.events e
    where e.crew_id = p_crew and e.status <> 'cancelled' and coalesce(e.raised, 0) > 0
      and extract(year from e.event_date) = p_year and public.in_crew(p_crew)
  ),
  w as (select ev.id as eid, x as pid from ev, public.event_workers(ev.id) x),
  others as (select w.eid, w.pid from w join ev on ev.id = w.eid where not (ev.hosted and ev.host_id is not null and w.pid = ev.host_id)),
  n as (select eid, count(*) as c from others group by eid)
  -- host share
  select ev.host_id, ev.id,
         round(ev.raised * case when coalesce(n.c, 0) = 0 then 100 else ev.host_share end / 100.0, 2)
  from ev left join n on n.eid = ev.id
  where ev.hosted and ev.host_id is not null
  union all
  -- everyone else splits the rest
  select o.pid, ev.id,
         round(ev.raised * (case when ev.hosted and ev.host_id is not null then 100 - ev.host_share else 100 end) / 100.0 / n.c, 2)
  from others o join ev on ev.id = o.eid join n on n.eid = o.eid;
$$;

create or replace function public.fundraising_board(p_crew uuid, p_year int)
returns table (person_id uuid, name text, amount numeric, events int)
language sql stable security definer set search_path = '' as $$
  select c.person_id, coalesce(p.callsign, p.full_name), sum(c.amount), count(distinct c.event_id)::int
  from public.fundraising_credit(p_crew, p_year) c join public.people p on p.id = c.person_id
  where c.amount > 0
  group by c.person_id, p.callsign, p.full_name
  order by sum(c.amount) desc, 2;
$$;

-- Editors (or the event's POC) set the money raised and how credit is shared.
create or replace function public.set_event_fundraising(p_event uuid, p_raised numeric, p_hosted boolean, p_host uuid, p_host_share int)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events; me uuid;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  me := public.me(e.crew_id);
  if not (public.can(e.crew_id, 'edit_events') or (e.poc_id is not null and e.poc_id = me)) then raise exception 'not allowed'; end if;
  if p_hosted and p_host is not null and not exists (select 1 from public.people x where x.id = p_host and x.crew_id = e.crew_id) then
    raise exception 'host must be in this crew';
  end if;
  update public.events set
    raised = p_raised,
    hosted = coalesce(p_hosted, false),
    host_id = case when coalesce(p_hosted, false) then p_host end,
    host_share = least(100, greatest(0, (coalesce(p_host_share, 90) / 10) * 10)),
    updated_at = now(), updated_by = me
  where id = p_event;
  perform public.log_action(e.crew_id, 'event_fundraising', 'event', p_event,
    e.title || ': raised ' || coalesce('$' || to_char(p_raised, 'FM999,999,990'), 'cleared')
    || case when p_hosted and p_host is not null then ', hosted (' || coalesce(p_host_share, 90) || '% to host)' else ', split evenly' end);
end $$;

revoke all on function public.event_workers(uuid), public.fundraising_credit(uuid, int) from public, anon, authenticated;
revoke all on function public.fundraising_board(uuid, int), public.set_event_fundraising(uuid, numeric, boolean, uuid, int) from public, anon;
grant execute on function public.fundraising_board(uuid, int), public.set_event_fundraising(uuid, numeric, boolean, uuid, int) to authenticated;
