create or replace function public.rsvp(p_event uuid, p_answer text, p_ride text default null, p_seats int default null, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events; me uuid;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or e.status not in ('scheduled') then raise exception 'event not open'; end if;
  me := public.me(e.crew_id);
  if me is null then raise exception 'not in this crew'; end if;
  if p_answer not in ('going','maybe','no') then raise exception 'bad answer'; end if;
  insert into public.rsvps (event_id, person_id, crew_id, answer, ride, seats, note, source)
    values (e.id, me, e.crew_id, p_answer, nullif(p_ride,''), case when p_ride = 'driving' then p_seats end, nullif(left(trim(p_note), 300),''), 'app')
  on conflict (event_id, person_id) do update set answer = excluded.answer, ride = excluded.ride, seats = excluded.seats,
    note = excluded.note, updated_at = now(), source = 'app',
    spot = case when excluded.answer = 'going' then public.rsvps.spot end;
end; $$;
