-- Personnel runs the crew's people from one list: status, roles, details, dues and nicknames.
-- Roles are bundles of abilities (Events team, Personnel, Media, Crew admin). Anyone with the Personnel ability
-- (manage_recruits) can now change them, crew admin included. App admin is separate and set only in the
-- Busters database (app_admins / app_admin_emails); nothing here can grant it.

-- Roster: add sign-in email, linked Discord, nicknames and events this year.
create or replace function public.personnel_roster(p_crew uuid) returns json
language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.can(p_crew, 'manage_recruits') then raise exception 'not allowed'; end if;
  return (select coalesce(json_agg(row_to_json(t) order by t.sort_status, t.full_name), '[]') from (
    select pe.id, pe.full_name, pe.callsign, pe.title, pe.status, pe.abilities, pe.member_since, pe.rookie_since, pe.eligible_date,
      pe.rookie_events_before, pe.city, pe.user_id is not null as signed_in,
      pp.email, pp.phone, pp.discord, pp.instagram, pp.birthday, pp.discord_user_id is not null as discord_linked,
      (select u.email from auth.users u where u.id = pe.user_id) as login_email,
      (select coalesce(json_agg(a.alias order by a.alias), '[]') from public.name_aliases a where a.person_id = pe.id) as aliases,
      (select coalesce(json_object_agg(d.year, d.status), '{}') from public.dues d where d.person_id = pe.id) as dues,
      (select count(*) from public.rsvps r join public.events e on e.id = r.event_id
         where r.person_id = pe.id and r.answer = 'going' and e.event_date < current_date and e.status <> 'cancelled')::int as events_done,
      (select count(*) from public.rsvps r join public.events e on e.id = r.event_id
         where r.person_id = pe.id and r.answer = 'going' and e.status <> 'cancelled'
           and extract(year from e.event_date) = extract(year from current_date))::int as events_year,
      case pe.status when 'pending' then 0 when 'rookie' then 1 when 'active' then 2 when 'retired' then 3 else 4 end as sort_status
    from public.people pe left join public.people_private pp on pp.person_id = pe.id
    where pe.crew_id = p_crew and pe.status <> 'declined'
  ) t);
end; $$;

-- Roles: Personnel (or Manage abilities) can change anyone's abilities in their crew.
create or replace function public.set_abilities(p_person uuid, p_abilities text[]) returns void
language plpgsql security definer set search_path to '' as $$
declare p public.people; clean text[];
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not (public.can(p.crew_id, 'manage_abilities') or public.can(p.crew_id, 'manage_recruits')) then raise exception 'not allowed'; end if;
  select coalesce(array_agg(distinct a order by a), '{}') into clean from unnest(p_abilities) a where a = any(public.all_abilities()) and a <> 'view_log';
  update public.people set abilities = clean, updated_at = now() where id = p.id;
  perform public.log_action(p.crew_id, 'abilities', 'person', p.id, 'Abilities for ' || p.full_name || ': ' || coalesce(nullif(array_to_string(clean, ', '), ''), 'member only'),
    jsonb_build_object('before', p.abilities, 'after', clean));
end; $$;

-- Nicknames Busters uses to match someone on the sheet and in Discord (like JP for Jose Padilla).
create or replace function public.set_aliases(p_person uuid, p_aliases text[]) returns void
language plpgsql security definer set search_path to '' as $$
declare p public.people; clean text[];
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not public.can(p.crew_id, 'manage_recruits') then raise exception 'not allowed'; end if;
  select coalesce(array_agg(distinct x), '{}') into clean
    from (select left(btrim(a), 60) x from unnest(p_aliases) a) s where x <> '' and lower(x) <> lower(p.full_name);
  if exists (select 1 from public.name_aliases a where a.crew_id = p.crew_id and a.person_id <> p.id and lower(a.alias) = any(select lower(c) from unnest(clean) c)) then
    raise exception 'That nickname already belongs to someone else';
  end if;
  delete from public.name_aliases where person_id = p.id;
  insert into public.name_aliases (crew_id, alias, person_id) select p.crew_id, c, p.id from unnest(clean) c;
  perform public.log_action(p.crew_id, 'aliases', 'person', p.id, 'Nicknames for ' || p.full_name || ': ' || coalesce(nullif(array_to_string(clean, ', '), ''), 'none'));
end; $$;
revoke all on function public.set_aliases(uuid, text[]) from public, anon;
grant execute on function public.set_aliases(uuid, text[]) to authenticated;
