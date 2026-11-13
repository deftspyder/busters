-- Megan's status on everyone in Personnel: Pass, Fail, or Check (no record yet). Stored in registry_checks
-- (outcome clear = Pass, review = Fail). Current members and rookies were checked before Busters, so they start as
-- Pass, marked "before Busters" (before_busters); only applicants start on Check.

alter table public.registry_checks add column if not exists before_busters boolean not null default false;

insert into public.registry_checks (person_id, crew_id, outcome, checked_by, checked_at, before_busters)
select p.id, p.crew_id, 'clear', null, now(), true from public.people p
where p.status in ('active', 'rookie')
on conflict (person_id) do nothing;

drop function if exists public.registry_checks_for(uuid);
create function public.registry_checks_for(p_crew uuid) returns table (person_id uuid, outcome text, checked_at timestamptz, checked_by text, before_busters boolean)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not (public.can(p_crew, 'approve_members') or public.can(p_crew, 'manage_recruits')) then raise exception 'not allowed'; end if;
  return query select r.person_id, r.outcome, r.checked_at, coalesce(b.callsign, b.full_name), r.before_busters
    from public.registry_checks r left join public.people b on b.id = r.checked_by where r.crew_id = p_crew;
end $$;
grant execute on function public.registry_checks_for(uuid) to authenticated;

-- A new mark is never "before Busters".
create or replace function public.set_registry_check(p_person uuid, p_outcome text) returns void
language plpgsql security definer set search_path to '' as $$
declare p public.people;
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not (public.can(p.crew_id, 'approve_members') or public.can(p.crew_id, 'manage_recruits')) then raise exception 'not allowed'; end if;
  if p_outcome is null then delete from public.registry_checks where person_id = p_person;
  elsif p_outcome in ('clear', 'review') then
    insert into public.registry_checks (person_id, crew_id, outcome, checked_by, checked_at, before_busters) values (p_person, p.crew_id, p_outcome, public.me(p.crew_id), now(), false)
      on conflict (person_id) do update set outcome = excluded.outcome, checked_by = excluded.checked_by, checked_at = now(), before_busters = false;
  else raise exception 'bad outcome'; end if;
  perform public.log_action(p.crew_id, 'registry_check', 'person', p_person,
    case when p_outcome is null then 'Reset the Megan''s check for ' else 'Recorded a Megan''s check for ' end || p.full_name);
end $$;
grant execute on function public.set_registry_check(uuid, text) to authenticated;
