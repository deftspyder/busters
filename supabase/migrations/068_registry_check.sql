-- Registry check for new applicants (Waiting): Personnel looks each one up on the California Megan's Law site and the
-- national NSOPW site, then marks it Clear or Needs a closer look. Busters records only the outcome, who checked and
-- when, never what was found. Only Personnel (approve_members / manage_recruits) and crew admins can see or set it.

create table if not exists public.registry_checks (
  person_id uuid primary key references public.people(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  outcome text not null check (outcome in ('clear', 'review')),
  checked_by uuid references public.people(id) on delete set null,
  checked_at timestamptz not null default now()
);
alter table public.registry_checks enable row level security;  -- no policies: read and written only through the functions below

create or replace function public.registry_checks_for(p_crew uuid) returns table (person_id uuid, outcome text, checked_at timestamptz, checked_by text)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not (public.can(p_crew, 'approve_members') or public.can(p_crew, 'manage_recruits')) then raise exception 'not allowed'; end if;
  return query select r.person_id, r.outcome, r.checked_at, coalesce(b.callsign, b.full_name)
    from public.registry_checks r left join public.people b on b.id = r.checked_by where r.crew_id = p_crew;
end $$;
grant execute on function public.registry_checks_for(uuid) to authenticated;

create or replace function public.set_registry_check(p_person uuid, p_outcome text) returns void
language plpgsql security definer set search_path to '' as $$
declare p public.people;
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not (public.can(p.crew_id, 'approve_members') or public.can(p.crew_id, 'manage_recruits')) then raise exception 'not allowed'; end if;
  if p_outcome is null then delete from public.registry_checks where person_id = p_person;
  elsif p_outcome in ('clear', 'review') then
    insert into public.registry_checks (person_id, crew_id, outcome, checked_by, checked_at) values (p_person, p.crew_id, p_outcome, public.me(p.crew_id), now())
      on conflict (person_id) do update set outcome = excluded.outcome, checked_by = excluded.checked_by, checked_at = now();
  else raise exception 'bad outcome'; end if;
  perform public.log_action(p.crew_id, 'registry_check', 'person', p_person,
    case when p_outcome is null then 'Cleared the registry check record for ' else 'Recorded a registry check for ' end || p.full_name);
end $$;
grant execute on function public.set_registry_check(uuid, text) to authenticated;
