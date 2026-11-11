-- Proton pack monitor: a crew's own pack photo plus where each monitored system sits on it.
-- {img: data URL, marks: {system_key: [x%, y%]}}. Set by crew admins from the monitor screen.
alter table public.crews add column if not exists pack_monitor jsonb not null default '{}'::jsonb;

create or replace function public.crew_settings(p_crew uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('members_map_mid', c.members_map_mid, 'donate_codes', c.donate_codes, 'pack_monitor', c.pack_monitor)
  from public.crews c where c.id = p_crew and public.in_crew(p_crew);
$$;

create or replace function public.set_pack_monitor(p_crew uuid, p_pack jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  if jsonb_typeof(p_pack) <> 'object' then raise exception 'bad pack settings'; end if;
  if coalesce(p_pack->>'img', '') <> '' and (p_pack->>'img' !~ '^data:image/(png|jpeg|webp);base64,' or length(p_pack->>'img') > 900000) then
    raise exception 'Pack photo must be a JPG or PNG under about 650 KB'; end if;
  if p_pack ? 'marks' and jsonb_typeof(p_pack->'marks') <> 'object' then raise exception 'bad marker list'; end if;
  update public.crews set pack_monitor = p_pack where id = p_crew;
  perform public.log_action(p_crew, 'pack_monitor', 'crew', p_crew, 'Proton pack monitor photo or markers updated');
end $$;
revoke all on function public.set_pack_monitor(uuid, jsonb) from public, anon;
grant execute on function public.set_pack_monitor(uuid, jsonb) to authenticated;
