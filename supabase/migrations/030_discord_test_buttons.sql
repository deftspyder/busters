-- Who a Discord account is in Busters (links it on first match). Used by test cards, whose buttons save nothing else.
create or replace function public.discord_match(p_app text, p_user text, p_username text, p_display text, p_nick text)
returns json language plpgsql security definer set search_path = '' as $$
declare c uuid; pid uuid; n int; norm text[] := array[lower(p_username), lower(p_display), lower(p_nick)];
begin
  select crew_id into c from public.crew_discord where app_id = p_app;
  if c is null then return json_build_object('status', 'unknown'); end if;
  select pp.person_id into pid from public.people_private pp join public.people p on p.id = pp.person_id
    where pp.crew_id = c and pp.discord_user_id = p_user and p.status in ('active', 'rookie');
  if pid is null then
    select count(*), min(pp.person_id::text)::uuid into n, pid from public.people_private pp join public.people p on p.id = pp.person_id
      where pp.crew_id = c and p.status in ('active', 'rookie') and pp.discord_user_id is null
        and lower(regexp_replace(trim(pp.discord), '^@|#0$', '')) = any (norm);
    if n = 1 then
      update public.people_private set discord_user_id = p_user where person_id = pid;
      delete from public.discord_unlinked where crew_id = c and discord_user_id = p_user;
    else
      insert into public.discord_unlinked (crew_id, discord_user_id, username, display_name)
      values (c, p_user, p_username, coalesce(p_nick, p_display))
      on conflict (crew_id, discord_user_id) do update set username = excluded.username, display_name = excluded.display_name, last_at = now();
      return json_build_object('status', 'unlinked');
    end if;
  end if;
  return json_build_object('status', 'ok', 'name', (select coalesce(callsign, full_name) from public.people where id = pid));
end $$;
revoke all on function public.discord_match(text, text, text, text, text) from public, anon, authenticated;
