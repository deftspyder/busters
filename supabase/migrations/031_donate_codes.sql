-- Donate QR codes: a short list of ways to give (Zelle for LAGB, Starlight Give Back, later Venmo),
-- shown big from the QR button in the top bar. Set by crew admins on the Team tab.
-- Each entry: {label, sub, url, img}. url is turned into a QR in the app; img is a fallback
-- picture of a QR code (data URL) for when only an image is available.

alter table public.crews add column if not exists donate_codes jsonb not null default '[]'::jsonb;

create or replace function public.crew_settings(p_crew uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('members_map_mid', c.members_map_mid, 'donate_codes', c.donate_codes)
  from public.crews c where c.id = p_crew and public.in_crew(p_crew);
$$;

create or replace function public.set_donate_codes(p_crew uuid, p_codes jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare e jsonb;
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
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
revoke all on function public.set_donate_codes(uuid, jsonb) from public, anon;
grant execute on function public.set_donate_codes(uuid, jsonb) to authenticated;

-- Start LAGB with the Starlight Give Back link already used in the menu.
update public.crews set donate_codes = jsonb_build_array(jsonb_build_object(
  'label', 'Donate to Starlight for LAGB',
  'sub', 'Ghostbusters Give Back, Starlight Children''s Foundation',
  'url', 'https://donate.starlight.org/fundraiser/3526698'))
where slug = 'lagb' and donate_codes = '[]'::jsonb;
