-- Crew members can reach an event's point of contact: returns only that one person's phone, only for events in your crew.
create or replace function public.poc_phone(p_event uuid) returns text
language sql stable security definer set search_path = '' as $$
  select pp.phone from public.events e
  join public.people_private pp on pp.person_id = e.poc_id
  where e.id = p_event and e.poc_id is not null and public.in_crew(e.crew_id);
$$;
revoke all on function public.poc_phone(uuid) from public, anon;
grant execute on function public.poc_phone(uuid) to authenticated;
