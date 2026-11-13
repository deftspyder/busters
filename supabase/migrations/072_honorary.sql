-- Honorary members (like Kevin Mangold, Slimer): shown with an Honorary status in Personnel and on their card. They
-- are full members everywhere else (status stays 'active', so sign-in, events, chat and adoption work as usual), but
-- they are exempt from dues and from the yearly event minimum. Their events still count in their stats.

alter table public.people add column if not exists honorary boolean not null default false;

update public.people set honorary = true
where crew_id = 'ee8915ed-35f5-4ba3-96bc-4710979962f6' and full_name = 'Kevin Mangold';

create or replace function public.set_honorary(p_person uuid, p_on boolean) returns void
language plpgsql security definer set search_path to '' as $$
declare p public.people;
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not public.can(p.crew_id, 'manage_recruits') then raise exception 'not allowed'; end if;
  update public.people set honorary = coalesce(p_on, false), status = case when coalesce(p_on, false) and status not in ('active') then 'active' else status end, updated_at = now() where id = p_person;
  perform public.log_action(p.crew_id, 'person_honorary', 'person', p_person, case when p_on then 'Made ' || p.full_name || ' an honorary member' else 'Ended honorary status for ' || p.full_name end);
end $$;
grant execute on function public.set_honorary(uuid, boolean) to authenticated;

-- Personnel list includes the flag.
do $$
declare d text := pg_get_functiondef('public.personnel_roster(uuid)'::regprocedure);
  f text := $x$pe.rookie_events_before, pe.city,$x$;
begin
  if position('pe.honorary' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'personnel_roster: column line not found once'; end if;
  execute replace(d, f, $x$pe.rookie_events_before, pe.city, pe.honorary,$x$);
end $$;

-- my_session returns the flag so the Me tab can show it.
do $$
declare d text := pg_get_functiondef('public.my_session(uuid)'::regprocedure);
  f text := $x$select p.id, p.full_name, p.callsign, p.title, p.status, p.abilities,$x$;
begin
  if position('p.honorary' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'my_session: person columns not found once'; end if;
  execute replace(d, f, $x$select p.id, p.full_name, p.callsign, p.title, p.status, p.honorary, p.abilities,$x$);
end $$;
