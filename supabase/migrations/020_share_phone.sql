-- Members can choose to show their phone number to the rest of their crew (off by default).
alter table public.people_private add column if not exists share_phone boolean not null default false;

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
    birthday = case when p ? 'birthday' then public.md(p->>'birthday') else birthday end,
    share_phone = coalesce((p->>'share_phone')::boolean, share_phone)
  where person_id = pid;
end; $$;

-- Phone numbers members chose to share, for their own crew only.
create or replace function public.shared_phones(p_crew uuid)
returns table (person_id uuid, phone text)
language sql stable security definer set search_path = '' as $$
  select pp.person_id, pp.phone from public.people_private pp
  join public.people p on p.id = pp.person_id
  where pp.crew_id = p_crew and pp.share_phone and pp.phone is not null
    and p.status in ('active','rookie') and public.in_crew(p_crew);
$$;
revoke all on function public.shared_phones(uuid) from public, anon;
grant execute on function public.shared_phones(uuid) to authenticated;

create or replace function public.my_session(p_crew uuid)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'app_admin', public.is_app_admin(),
    'person', (select row_to_json(x) from (select p.id, p.full_name, p.callsign, p.title, p.status, p.abilities, p.city, p.show_on_map, p.member_since
               from public.people p where p.crew_id = p_crew and p.user_id = (select auth.uid())) x),
    'private', (select row_to_json(x) from (select pp.phone, pp.discord, pp.instagram, pp.birthday, pp.email, pp.share_phone
               from public.people_private pp join public.people p on p.id = pp.person_id where p.crew_id = p_crew and p.user_id = (select auth.uid())) x),
    'dues', (select coalesce(json_object_agg(d.year, d.status), '{}') from public.dues d join public.people p on p.id = d.person_id
               where p.crew_id = p_crew and p.user_id = (select auth.uid())),
    'profile', (select row_to_json(x) from (select pr.display_name, pr.maps_app, pr.alert_short, pr.alert_days, pr.alert_lastcall
               from public.profiles pr where pr.id = (select auth.uid())) x)
  );
$$;
