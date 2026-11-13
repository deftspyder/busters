create or replace function public.crew_settings(p_crew uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('members_map_mid', c.members_map_mid) from public.crews c where c.id = p_crew and public.in_crew(p_crew);
$$;
revoke all on function public.crew_settings(uuid) from public, anon;
grant execute on function public.crew_settings(uuid) to authenticated;
