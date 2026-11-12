-- Fix: Discord PUT/POST/PATCH calls with no body failed silently (the http extension rejects a NULL body), so
-- adding people to threads and pinning photo calls never happened. Those now send an empty JSON object.

create or replace function public.dc_http(p_crew uuid, p_method text, p_path text, p_body jsonb) returns integer
language plpgsql security definer set search_path = public, extensions as $$
declare d public.crew_discord; r record; b jsonb := p_body;
begin
  select * into d from public.crew_discord where crew_id = p_crew;
  if d.bot_token is null then return null; end if;
  if b is null and p_method in ('PUT', 'POST', 'PATCH') then b := '{}'::jsonb; end if;
  select status into r from extensions.http((
    p_method, 'https://discord.com/api/v10' || p_path,
    array[extensions.http_header('Authorization', 'Bot ' || d.bot_token),
          extensions.http_header('User-Agent', 'DiscordBot (https://busters.app, 1)')],
    case when b is null then null else 'application/json' end, b::text)::extensions.http_request);
  return r.status;
exception when others then return -1;
end $$;
