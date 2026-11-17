-- Fundraising role (Bill, Nov 17): its own ability, so money work doesn't need Crew admin.
-- Fundraising can enter money raised on any event, publish the credit split to the leaderboard,
-- set the Give Back goal and manage the donate QR codes. Crew admin still covers all of it.

create or replace function public.all_abilities() returns text[] language sql immutable set search_path to '' as $$
  select array['add_events','edit_events','manage_proposals','pick_attendees','poc','take_attendance',
               'approve_members','manage_recruits','webmaster','manage_abilities','inbox_alerts','view_log','fundraising','crew_admin'];
$$;

create or replace function public.preset_abilities(preset text) returns text[] language sql immutable set search_path to '' as $$
  select case lower(coalesce(preset, 'member'))
    when 'events team' then array['add_events','edit_events','manage_proposals','pick_attendees','poc','take_attendance']
    when 'personnel'   then array['approve_members','manage_recruits']
    when 'fundraising' then array['fundraising']
    when 'admin'       then array['crew_admin']
    else '{}'::text[] end;
$$;

create or replace function public.set_donate_codes(p_crew uuid, p_codes jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare e jsonb;
begin
  if not public.can(p_crew, 'fundraising') then raise exception 'not allowed'; end if;
  if jsonb_typeof(p_codes) <> 'array' or jsonb_array_length(p_codes) > 4 then raise exception 'Up to 4 codes'; end if;
  for e in select * from jsonb_array_elements(p_codes) loop
    if coalesce(trim(e->>'label'), '') = '' then raise exception 'Each code needs a name'; end if;
    if coalesce(e->>'url', '') = '' and coalesce(e->>'img', '') = '' then raise exception 'Each code needs a link or a QR picture'; end if;
    if coalesce(e->>'url', '') <> '' and e->>'url' !~* '^https://' then raise exception 'Links must start with https://'; end if;
    if coalesce(e->>'img', '') <> '' and (e->>'img' !~ '^data:image/(png|jpeg|webp);base64,' or length(e->>'img') > 300000) then raise exception 'QR picture must be a PNG or JPG under 200 KB'; end if;
  end loop;
  update public.crews set donate_codes = p_codes where id = p_crew;
  perform public.log_action(p_crew, 'donate_codes', 'crew', p_crew,
    'Donate QR codes updated (' || jsonb_array_length(p_codes) || ')');
end $$;

create or replace function public.set_giveback_goal(p_crew uuid, p_goal numeric, p_last_total numeric, p_ends date default null)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.can(p_crew, 'fundraising') then raise exception 'not allowed'; end if;
  update public.crews set give_back_last_total = p_last_total,
         give_back_goal = coalesce(p_goal, p_last_total),
         give_back_ends = coalesce(p_ends, give_back_ends)
   where id = p_crew;
  perform public.log_action(p_crew, 'giveback_goal', 'crew', p_crew,
    'Give Back goal set to $' || coalesce(to_char(coalesce(p_goal, p_last_total), 'FM999,999,990'), 'none')
    || coalesce(' (last drive $' || to_char(p_last_total, 'FM999,999,990') || ')', '')
    || coalesce(', ends ' || to_char(p_ends, 'Mon FMDD, YYYY'), ''));
end $$;

create or replace function public.set_event_fundraising(p_event uuid, p_raised numeric, p_hosted boolean, p_host uuid, p_host_share integer, p_publish boolean)
returns void language plpgsql security definer set search_path to '' as $$
declare e public.events; me uuid; adm boolean; pub boolean;
begin
  select * into e from public.events where id = p_event;
  if e.id is null then raise exception 'not found'; end if;
  me := public.me(e.crew_id); adm := public.can(e.crew_id, 'fundraising');
  if not (adm or public.can(e.crew_id, 'edit_events') or (e.poc_id is not null and e.poc_id = me)) then raise exception 'not allowed'; end if;
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

-- Matt Zunich gets it first (LAGB).
update public.people set abilities = array(select distinct a from unnest(abilities || array['fundraising']) a order by a), updated_at = now()
 where full_name = 'Matt Zunich' and crew_id = (select id from public.crews where slug = 'lagb') and not ('fundraising' = any(abilities));
