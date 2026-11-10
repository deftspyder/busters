-- Fundraising credit stays hidden (draft) until a crew admin publishes the split.
alter table public.events add column if not exists credit_published boolean not null default false;

create or replace view public.events_full with (security_invoker = true) as
 select e.id, e.crew_id, e.title, e.category, e.status, e.event_date, e.end_date, e.call_time, e.start_time, e.wrap_time,
    e.schedule, e.parking, e.conditions, e.notes, e.contact_name, e.contact_phone, e.contact_email, e.poc_id,
    e.min_busters, e.goal_busters, e.max_busters, e.source, e.source_key, e.proposed_by, e.created_by, e.created_at,
    e.updated_at, e.updated_by, e.lagb_contact, e.sheet_attendees, e.sheet_reserve,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going')::int as going,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'maybe')::int as maybe,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going' and r.spot = 'in')::int as spots_in,
    public.event_missing(e.*) as missing,
    e.raised, e.hosted, e.host_id, e.host_share, e.credit_published
   from public.events e;

create or replace function public.fundraising_credit(p_crew uuid, p_year int)
returns table (person_id uuid, event_id uuid, amount numeric)
language sql stable security definer set search_path = '' as $$
  with ev as (
    select e.* from public.events e
    where e.crew_id = p_crew and e.status <> 'cancelled' and coalesce(e.raised, 0) > 0 and e.credit_published
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

drop function if exists public.set_event_fundraising(uuid, numeric, boolean, uuid, int);
-- Editors save a draft; only crew admins publish. Any change by a non-admin puts the split back to draft.
create or replace function public.set_event_fundraising(p_event uuid, p_raised numeric, p_hosted boolean, p_host uuid, p_host_share int, p_publish boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events; me uuid; adm boolean; pub boolean;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  me := public.me(e.crew_id); adm := public.can(e.crew_id, 'crew_admin');
  if not (public.can(e.crew_id, 'edit_events') or (e.poc_id is not null and e.poc_id = me)) then raise exception 'not allowed'; end if;
  if p_hosted and p_host is not null and not exists (select 1 from public.people x where x.id = p_host and x.crew_id = e.crew_id) then
    raise exception 'host must be in this crew';
  end if;
  pub := case when adm then coalesce(p_publish, false) else false end;
  update public.events set
    raised = p_raised,
    hosted = coalesce(p_hosted, false),
    host_id = case when coalesce(p_hosted, false) then p_host end,
    host_share = least(100, greatest(0, (coalesce(p_host_share, 90) / 10) * 10)),
    credit_published = pub,
    updated_at = now(), updated_by = me
  where id = p_event;
  perform public.log_action(e.crew_id, case when pub then 'credit_published' else 'event_fundraising' end, 'event', p_event,
    e.title || ': raised ' || coalesce('$' || to_char(p_raised, 'FM999,999,990'), 'cleared')
    || case when p_hosted and p_host is not null then ', hosted (' || coalesce(p_host_share, 90) || '% to host)' else ', split evenly' end
    || case when pub then ', published' else ', draft' end);
end $$;
revoke all on function public.set_event_fundraising(uuid, numeric, boolean, uuid, int, boolean) from public, anon;
grant execute on function public.set_event_fundraising(uuid, numeric, boolean, uuid, int, boolean) to authenticated;
