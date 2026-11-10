-- A crew can point its members map at a Google My Maps. The map id is set in the database
-- (crews.members_map_mid), not stored in this repo, so the link stays crew-only.
alter table public.crews add column if not exists members_map_mid text check (members_map_mid is null or members_map_mid ~ '^[A-Za-z0-9_-]{10,80}$');

create or replace function public.crew_settings(p_crew uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('members_map_mid', c.members_map_mid) from public.crews c where c.id = p_crew and public.in_crew(p_crew);
$$;
revoke all on function public.crew_settings(uuid) from public, anon;
grant execute on function public.crew_settings(uuid) to authenticated;
