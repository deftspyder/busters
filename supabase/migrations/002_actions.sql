-- Busters actions: every write goes through one of these functions.
-- Each checks the caller's abilities and records itself in the action log.

-- Abilities each preset turns on. 'crew_admin' implies every ability.
create or replace function public.preset_abilities(preset text) returns text[]
language sql immutable set search_path = '' as $$
  select case lower(coalesce(preset, 'member'))
    when 'events team' then array['add_events','edit_events','manage_proposals','pick_attendees','poc','take_attendance']
    when 'personnel'   then array['approve_members','manage_recruits']
    when 'admin'       then array['crew_admin']
    else '{}'::text[] end;
$$;

create or replace function public.all_abilities() returns text[]
language sql immutable set search_path = '' as $$
  select array['add_events','edit_events','manage_proposals','pick_attendees','poc','take_attendance',
               'approve_members','manage_recruits','webmaster','manage_abilities','inbox_alerts','view_log','crew_admin'];
$$;

-- What an event still needs before it is complete.
create or replace function public.event_missing(e public.events) returns text[]
language sql stable security definer set search_path = '' as $$
  select array_remove(array[
    case when e.poc_id is null then 'Point of contact' end,
    case when coalesce(e.contact_name, '') = '' or (coalesce(e.contact_phone, '') = '' and coalesce(e.contact_email, '') = '') then 'Event contact' end,
    case when not exists (select 1 from public.event_places ep join public.places pl on pl.id = ep.place_id
                          where ep.event_id = e.id and coalesce(pl.address, '') <> '') then 'Address' end,
    case when e.call_time is null then 'Call time' end,
    case when e.start_time is null then 'Start time' end,
    case when e.wrap_time is null then 'Wrap time' end,
    case when e.min_busters is null then 'Minimum Busters' end,
    case when e.goal_busters is null then 'Goal' end
  ], null);
$$;

-- Events with counts and what is missing. Uses the caller's own row rules.
create or replace view public.events_full with (security_invoker = true) as
  select e.*,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going')::int as going,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'maybe')::int as maybe,
    (select count(*) from public.rsvps r where r.event_id = e.id and r.answer = 'going' and r.spot = 'in')::int as spots_in,
    public.event_missing(e) as missing
  from public.events e;

-- ---------- joining ----------
-- Called after sign-in. Links a pre-approved row by email, or files a join request.
create or replace function public.enter_crew(p_slug text, p_name text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); em text; c public.crews; p public.people; pid uuid;
begin
  if uid is null then raise exception 'sign in first'; end if;
  select * into c from public.crews where slug = lower(p_slug);
  if c.id is null then return json_build_object('status', 'no_crew'); end if;
  select lower(email) into em from auth.users where id = uid;

  select * into p from public.people where crew_id = c.id and user_id = uid;
  if p.id is null and em is not null then
    select pe.* into p from public.people pe join public.people_private pp on pp.person_id = pe.id
      where pe.crew_id = c.id and pe.user_id is null and lower(pp.email) = em limit 1;
    if p.id is not null then
      update public.people set user_id = uid, updated_at = now() where id = p.id;
      insert into public.action_log (crew_id, actor_id, action, target_type, target_id, summary)
        values (c.id, p.id, 'joined', 'person', p.id, p.full_name || ' signed in for the first time (pre-approved)');
    end if;
  end if;

  if p.id is null then
    if coalesce(trim(p_name), '') = '' then
      return json_build_object('status', 'need_name', 'crew', c.short_name);
    end if;
    insert into public.people (crew_id, user_id, full_name, status)
      values (c.id, uid, left(trim(p_name), 80), 'pending') returning * into p;
    insert into public.people_private (person_id, crew_id, email) values (p.id, c.id, em)
      on conflict do nothing;
    insert into public.action_log (crew_id, actor_id, action, target_type, target_id, summary)
      values (c.id, p.id, 'join_request', 'person', p.id, p.full_name || ' asked to join');
  end if;

  return json_build_object('status', p.status, 'crew_id', c.id, 'crew', c.short_name, 'person_id', p.id);
end; $$;

create or replace function public.decide_member(p_person uuid, p_approve boolean, p_preset text default 'member')
returns void language plpgsql security definer set search_path = '' as $$
declare p public.people;
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not public.can(p.crew_id, 'approve_members') then raise exception 'not allowed'; end if;
  if p.status <> 'pending' then raise exception 'already decided'; end if;
  if p_approve and lower(coalesce(p_preset,'member')) = 'admin' and not public.can(p.crew_id, 'manage_abilities') then
    raise exception 'only someone who manages abilities can make an admin';
  end if;
  update public.people set
    status = case when p_approve then 'active' else 'declined' end,
    abilities = case when p_approve then public.preset_abilities(p_preset) else '{}' end,
    approved_by = public.me(p.crew_id), approved_at = now(), updated_at = now(),
    member_since = case when p_approve then coalesce(member_since, current_date) end
  where id = p.id;
  perform public.log_action(p.crew_id, case when p_approve then 'approved' else 'declined' end, 'person', p.id,
    case when p_approve then 'Approved ' || p.full_name || ' as ' || coalesce(p_preset, 'Member') else 'Declined ' || p.full_name end);
end; $$;

create or replace function public.set_abilities(p_person uuid, p_abilities text[])
returns void language plpgsql security definer set search_path = '' as $$
declare p public.people; clean text[];
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not public.can(p.crew_id, 'manage_abilities') then raise exception 'not allowed'; end if;
  select coalesce(array_agg(distinct a order by a), '{}') into clean from unnest(p_abilities) a where a = any(public.all_abilities());
  update public.people set abilities = clean, updated_at = now() where id = p.id;
  perform public.log_action(p.crew_id, 'abilities', 'person', p.id, 'Abilities for ' || p.full_name || ': ' || coalesce(nullif(array_to_string(clean, ', '), ''), 'member only'),
    jsonb_build_object('before', p.abilities, 'after', clean));
end; $$;

-- ---------- personnel ----------
-- Add someone to the roster (pre-approved), or update them. Personnel only.
create or replace function public.save_person(p_crew uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare pid uuid := nullif(p->>'id','')::uuid; before public.people; nm text;
begin
  if not public.can(p_crew, 'manage_recruits') then raise exception 'not allowed'; end if;
  nm := nullif(trim(p->>'full_name'), '');
  if pid is null then
    if nm is null then raise exception 'name required'; end if;
    insert into public.people (crew_id, full_name, callsign, title, status, abilities, member_since, rookie_since, eligible_date)
    values (p_crew, nm, nullif(p->>'callsign',''), nullif(p->>'title',''), coalesce(nullif(p->>'status',''), 'active'),
            case when public.can(p_crew, 'manage_abilities') then public.preset_abilities(p->>'preset') else '{}' end,
            nullif(p->>'member_since','')::date, nullif(p->>'rookie_since','')::date, nullif(p->>'eligible_date','')::date)
    returning id into pid;
    insert into public.people_private (person_id, crew_id) values (pid, p_crew);
    perform public.log_action(p_crew, 'person_added', 'person', pid, 'Added ' || nm || ' to the roster');
  else
    select * into before from public.people where id = pid and crew_id = p_crew;
    if before.id is null then raise exception 'not found'; end if;
    update public.people set
      full_name = coalesce(nm, full_name),
      callsign = case when p ? 'callsign' then nullif(p->>'callsign','') else callsign end,
      title = case when p ? 'title' then nullif(p->>'title','') else title end,
      status = case when p ? 'status' and p->>'status' in ('active','rookie','retired','removed') then p->>'status' else status end,
      member_since = case when p ? 'member_since' then nullif(p->>'member_since','')::date else member_since end,
      rookie_since = case when p ? 'rookie_since' then nullif(p->>'rookie_since','')::date else rookie_since end,
      eligible_date = case when p ? 'eligible_date' then nullif(p->>'eligible_date','')::date else eligible_date end,
      updated_at = now()
    where id = pid;
    perform public.log_action(p_crew, 'person_edited', 'person', pid, 'Edited ' || before.full_name);
  end if;
  update public.people_private set
    email = case when p ? 'email' then nullif(lower(trim(p->>'email')),'') else email end,
    phone = case when p ? 'phone' then nullif(trim(p->>'phone'),'') else phone end,
    discord = case when p ? 'discord' then nullif(trim(p->>'discord'),'') else discord end,
    instagram = case when p ? 'instagram' then nullif(trim(p->>'instagram'),'') else instagram end,
    birthday = case when p ? 'birthday' then nullif(p->>'birthday','')::date else birthday end
  where person_id = pid;
  return pid;
end; $$;

create or replace function public.set_dues(p_person uuid, p_year int, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.people;
begin
  select * into p from public.people where id = p_person;
  if p.id is null or not public.can(p.crew_id, 'manage_recruits') then raise exception 'not allowed'; end if;
  if coalesce(trim(p_status), '') = '' then
    delete from public.dues where person_id = p.id and year = p_year;
  else
    insert into public.dues (person_id, crew_id, year, status) values (p.id, p.crew_id, p_year, trim(p_status))
      on conflict (person_id, year) do update set status = excluded.status, updated_at = now();
  end if;
  perform public.log_action(p.crew_id, 'dues', 'person', p.id, p_year || ' dues for ' || p.full_name || ': ' || coalesce(nullif(trim(p_status),''), 'cleared'));
end; $$;

-- Everything Personnel needs on one screen.
create or replace function public.personnel_roster(p_crew uuid)
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'manage_recruits') then raise exception 'not allowed'; end if;
  return (select coalesce(json_agg(row_to_json(t) order by t.sort_status, t.full_name), '[]') from (
    select pe.id, pe.full_name, pe.callsign, pe.title, pe.status, pe.abilities, pe.member_since, pe.rookie_since, pe.eligible_date,
      pe.city, pe.user_id is not null as signed_in,
      pp.email, pp.phone, pp.discord, pp.instagram, pp.birthday,
      (select coalesce(json_object_agg(d.year, d.status), '{}') from public.dues d where d.person_id = pe.id) as dues,
      (select count(*) from public.rsvps r join public.events e on e.id = r.event_id
         where r.person_id = pe.id and r.answer = 'going' and e.event_date < current_date and e.status <> 'cancelled')::int as events_done,
      case pe.status when 'pending' then 0 when 'rookie' then 1 when 'active' then 2 when 'retired' then 3 else 4 end as sort_status
    from public.people pe left join public.people_private pp on pp.person_id = pe.id
    where pe.crew_id = p_crew and pe.status <> 'declined'
  ) t);
end; $$;

create or replace function public.log_export(p_crew uuid, p_what text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'manage_recruits') then raise exception 'not allowed'; end if;
  perform public.log_action(p_crew, 'export', 'crew', p_crew, 'Downloaded ' || p_what);
end; $$;

-- A member updates their own details.
create or replace function public.save_my_details(p_crew uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare pid uuid;
begin
  select id into pid from public.people where crew_id = p_crew and user_id = auth.uid();
  if pid is null then raise exception 'not in this crew'; end if;
  update public.people set
    callsign = case when p ? 'callsign' then nullif(trim(p->>'callsign'),'') else callsign end,
    city = case when p ? 'city' then nullif(trim(p->>'city'),'') else city end,
    show_on_map = coalesce((p->>'show_on_map')::boolean, show_on_map),
    updated_at = now()
  where id = pid;
  update public.people_private set
    phone = case when p ? 'phone' then nullif(trim(p->>'phone'),'') else phone end,
    discord = case when p ? 'discord' then nullif(trim(p->>'discord'),'') else discord end,
    instagram = case when p ? 'instagram' then nullif(trim(p->>'instagram'),'') else instagram end,
    birthday = case when p ? 'birthday' then nullif(p->>'birthday','')::date else birthday end
  where person_id = pid;
end; $$;

-- ---------- events ----------
create or replace function public.save_event(p_crew uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare eid uuid := nullif(p->>'id','')::uuid; before public.events; after public.events; me uuid := public.me(p_crew);
        is_poc boolean; changed text[] := '{}'; k text;
begin
  if me is null and not public.is_app_admin() then raise exception 'not in this crew'; end if;
  if eid is null then
    if not public.can(p_crew, 'add_events') then
      -- members can only propose
      if coalesce(p->>'status','') <> 'proposed' then raise exception 'not allowed'; end if;
    end if;
    if coalesce(trim(p->>'title'),'') = '' or nullif(p->>'event_date','') is null then raise exception 'name and date required'; end if;
    insert into public.events (crew_id, title, status, event_date, created_by, updated_by, proposed_by)
      values (p_crew, trim(p->>'title'), case when p->>'status' = 'proposed' then 'proposed' else 'scheduled' end,
              (p->>'event_date')::date, me, me, case when p->>'status' = 'proposed' then me end)
      returning id into eid;
    select * into before from public.events where id = eid;
  else
    select * into before from public.events where id = eid and crew_id = p_crew;
    if before.id is null then raise exception 'not found'; end if;
    is_poc := before.poc_id is not null and before.poc_id = me;
    if not (public.can(p_crew, 'edit_events') or is_poc) then raise exception 'not allowed'; end if;
  end if;

  update public.events set
    title = coalesce(nullif(trim(p->>'title'),''), title),
    category = case when p ? 'category' then nullif(p->>'category','') else category end,
    event_date = coalesce(nullif(p->>'event_date','')::date, event_date),
    end_date = case when p ? 'end_date' then nullif(p->>'end_date','')::date else end_date end,
    call_time = case when p ? 'call_time' then nullif(p->>'call_time','')::time else call_time end,
    start_time = case when p ? 'start_time' then nullif(p->>'start_time','')::time else start_time end,
    wrap_time = case when p ? 'wrap_time' then nullif(p->>'wrap_time','')::time else wrap_time end,
    schedule = case when p ? 'schedule' then nullif(p->>'schedule','') else schedule end,
    parking = case when p ? 'parking' then nullif(p->>'parking','') else parking end,
    conditions = case when p ? 'conditions' then nullif(p->>'conditions','') else conditions end,
    notes = case when p ? 'notes' then nullif(p->>'notes','') else notes end,
    contact_name = case when p ? 'contact_name' then nullif(p->>'contact_name','') else contact_name end,
    contact_phone = case when p ? 'contact_phone' then nullif(p->>'contact_phone','') else contact_phone end,
    contact_email = case when p ? 'contact_email' then nullif(p->>'contact_email','') else contact_email end,
    poc_id = case when p ? 'poc_id' then nullif(p->>'poc_id','')::uuid else poc_id end,
    min_busters = case when p ? 'min_busters' then nullif(p->>'min_busters','')::int else min_busters end,
    goal_busters = case when p ? 'goal_busters' then nullif(p->>'goal_busters','')::int else goal_busters end,
    max_busters = case when p ? 'max_busters' then nullif(p->>'max_busters','')::int else max_busters end,
    updated_at = now(), updated_by = me
  where id = eid returning * into after;

  -- the POC must hold the POC ability and belong to this crew
  if after.poc_id is not null and after.poc_id is distinct from before.poc_id then
    if not exists (select 1 from public.people x where x.id = after.poc_id and x.crew_id = p_crew and x.status in ('active','rookie')
                   and ('poc' = any(x.abilities) or 'crew_admin' = any(x.abilities))) then
      raise exception 'that person cannot be point of contact';
    end if;
  end if;

  for k in select key from jsonb_each(to_jsonb(after)) loop
    if k not in ('updated_at','updated_by') and (to_jsonb(before)->k) is distinct from (to_jsonb(after)->k) then changed := changed || k; end if;
  end loop;

  if nullif(p->>'id','') is null then
    perform public.log_action(p_crew, case when after.status = 'proposed' then 'event_proposed' else 'event_created' end, 'event', eid,
      after.title || ' on ' || to_char(after.event_date, 'Mon DD'));
  elsif cardinality(changed) > 0 then
    perform public.log_action(p_crew, case when 'poc_id' = any(changed) then 'event_poc' else 'event_edited' end, 'event', eid,
      'Edited ' || after.title || ': ' || array_to_string(changed, ', '), jsonb_build_object('changed', changed));
  end if;
  return eid;
end; $$;

create or replace function public.set_event_status(p_event uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  if p_status not in ('scheduled','cancelled','closed') then raise exception 'bad status'; end if;
  if e.status = 'proposed' then
    if not public.can(e.crew_id, 'manage_proposals') then raise exception 'not allowed'; end if;
  elsif not (public.can(e.crew_id, 'edit_events') or e.poc_id = public.me(e.crew_id)) then raise exception 'not allowed'; end if;
  update public.events set status = p_status, updated_at = now(), updated_by = public.me(e.crew_id) where id = e.id;
  perform public.log_action(e.crew_id, 'event_' || p_status, 'event', e.id,
    case p_status when 'cancelled' then 'Cancelled ' when 'closed' then 'Closed ' else 'Scheduled ' end || e.title || coalesce(': ' || nullif(p_reason,''), ''));
end; $$;

create or replace function public.delete_event(p_event uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or not public.can(e.crew_id, 'edit_events') then raise exception 'not allowed'; end if;
  perform public.log_action(e.crew_id, 'event_deleted', 'event', e.id, 'Deleted ' || e.title || ' (' || e.event_date || ')', to_jsonb(e));
  delete from public.events where id = e.id;
end; $$;

-- Replace an event's places. Each item: {place_id?, name, address, label}. New names become saved places.
create or replace function public.set_event_places(p_event uuid, p_places jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events; it jsonb; pid uuid; n int := 0;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or not (public.can(e.crew_id, 'edit_events') or public.can(e.crew_id, 'add_events') and e.created_by = public.me(e.crew_id)
                          or e.poc_id = public.me(e.crew_id)) then raise exception 'not allowed'; end if;
  delete from public.event_places where event_id = e.id;
  for it in select * from jsonb_array_elements(coalesce(p_places, '[]')) loop
    pid := nullif(it->>'place_id','')::uuid;
    if pid is not null and not exists (select 1 from public.places where id = pid and crew_id = e.crew_id) then pid := null; end if;
    if pid is null then
      if coalesce(trim(it->>'name'),'') = '' and coalesce(trim(it->>'address'),'') = '' then continue; end if;
      select id into pid from public.places where crew_id = e.crew_id and retired_at is null
        and lower(name) = lower(coalesce(nullif(trim(it->>'name'),''), trim(it->>'address')))
        and lower(coalesce(address,'')) = lower(coalesce(trim(it->>'address'),'')) limit 1;
      if pid is null then
        insert into public.places (crew_id, name, address, kind)
          values (e.crew_id, coalesce(nullif(trim(it->>'name'),''), trim(it->>'address')), nullif(trim(it->>'address'),''), nullif(trim(it->>'label'),''))
          returning id into pid;
      end if;
    end if;
    insert into public.event_places (event_id, crew_id, place_id, label, sort)
      values (e.id, e.crew_id, pid, coalesce(nullif(trim(it->>'label'),''), 'Event'), n);
    n := n + 1;
  end loop;
  perform public.log_action(e.crew_id, 'event_places', 'event', e.id, 'Updated places for ' || e.title);
end; $$;

create or replace function public.retire_place(p_place uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare pl public.places;
begin
  select * into pl from public.places where id = p_place;
  if pl.id is null or not public.can(pl.crew_id, 'edit_events') then raise exception 'not allowed'; end if;
  update public.places set retired_at = now() where id = pl.id;
  perform public.log_action(pl.crew_id, 'place_retired', 'place', pl.id, 'Retired place ' || pl.name);
end; $$;

-- Going / Maybe / No for yourself.
create or replace function public.rsvp(p_event uuid, p_answer text, p_ride text default null, p_seats int default null, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events; me uuid;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or e.status not in ('scheduled') then raise exception 'event not open'; end if;
  me := public.me(e.crew_id);
  if me is null then raise exception 'not in this crew'; end if;
  if p_answer not in ('going','maybe','no') then raise exception 'bad answer'; end if;
  insert into public.rsvps (event_id, person_id, crew_id, answer, ride, seats, note)
    values (e.id, me, e.crew_id, p_answer, nullif(p_ride,''), case when p_ride = 'driving' then p_seats end, nullif(left(trim(p_note), 300),''))
  on conflict (event_id, person_id) do update set answer = excluded.answer, ride = excluded.ride, seats = excluded.seats,
    note = excluded.note, updated_at = now(),
    spot = case when excluded.answer = 'going' then public.rsvps.spot end;
end; $$;

-- Limited events: who is In and who is on Reserve.
create or replace function public.set_spot(p_event uuid, p_person uuid, p_spot text)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events; nm text;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or not public.can(e.crew_id, 'pick_attendees') then raise exception 'not allowed'; end if;
  update public.rsvps set spot = nullif(p_spot,''), updated_at = now() where event_id = e.id and person_id = p_person;
  select full_name into nm from public.people where id = p_person;
  perform public.log_action(e.crew_id, 'spot', 'event', e.id, coalesce(nm,'Someone') || ' set to ' || coalesce(nullif(p_spot,''),'undecided') || ' for ' || e.title);
end; $$;

-- ---------- announcements ----------
create or replace function public.post_announcement(p_crew uuid, p_body text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare aid uuid;
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  insert into public.announcements (crew_id, author_id, body) values (p_crew, public.me(p_crew), trim(p_body)) returning id into aid;
  perform public.log_action(p_crew, 'announcement', 'announcement', aid, left(trim(p_body), 80));
  return aid;
end; $$;

create or replace function public.delete_announcement(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.announcements;
begin
  select * into a from public.announcements where id = p_id;
  if a.id is null or not public.can(a.crew_id, 'crew_admin') then raise exception 'not allowed'; end if;
  delete from public.announcements where id = a.id;
  perform public.log_action(a.crew_id, 'announcement_deleted', 'announcement', a.id, left(a.body, 80));
end; $$;

-- ---------- what the app loads on start ----------
create or replace function public.my_session(p_crew uuid)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'app_admin', public.is_app_admin(),
    'person', (select row_to_json(x) from (select p.id, p.full_name, p.callsign, p.title, p.status, p.abilities, p.city, p.show_on_map, p.member_since
               from public.people p where p.crew_id = p_crew and p.user_id = (select auth.uid())) x),
    'private', (select row_to_json(x) from (select pp.phone, pp.discord, pp.instagram, pp.birthday, pp.email
               from public.people_private pp join public.people p on p.id = pp.person_id where p.crew_id = p_crew and p.user_id = (select auth.uid())) x),
    'dues', (select coalesce(json_object_agg(d.year, d.status), '{}') from public.dues d join public.people p on p.id = d.person_id
               where p.crew_id = p_crew and p.user_id = (select auth.uid())),
    'profile', (select row_to_json(x) from (select pr.display_name, pr.maps_app from public.profiles pr where pr.id = (select auth.uid())) x)
  );
$$;

create or replace function public.set_maps_app(p_app text)
returns void language sql security definer set search_path = '' as $$
  update public.profiles set maps_app = p_app where id = (select auth.uid()) and p_app in ('google','apple','waze');
$$;

-- Lock down: only signed-in users can call the actions; helpers stay internal where they should.
revoke execute on all functions in schema public from public, anon;
grant execute on function public.enter_crew(text, text), public.decide_member(uuid, boolean, text), public.set_abilities(uuid, text[]),
  public.save_person(uuid, jsonb), public.set_dues(uuid, int, text), public.personnel_roster(uuid), public.log_export(uuid, text),
  public.save_my_details(uuid, jsonb), public.save_event(uuid, jsonb), public.set_event_status(uuid, text, text), public.delete_event(uuid),
  public.set_event_places(uuid, jsonb), public.retire_place(uuid), public.rsvp(uuid, text, text, int, text), public.set_spot(uuid, uuid, text),
  public.post_announcement(uuid, text), public.delete_announcement(uuid), public.my_session(uuid), public.set_maps_app(text),
  public.is_app_admin(), public.me(uuid), public.in_crew(uuid), public.can(uuid, text), public.event_missing(public.events),
  public.preset_abilities(text), public.all_abilities()
  to authenticated;
revoke execute on function public.log_action(uuid, text, text, uuid, text, jsonb) from authenticated;
revoke execute on function public.handle_new_user() from authenticated;

-- Crew lookup before sign-in (name only), for the sign-in screen.
create or replace function public.crew_public(p_slug text)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('name', c.name, 'short_name', c.short_name) from public.crews c where c.slug = lower(p_slug);
$$;
grant execute on function public.crew_public(text) to anon, authenticated;
