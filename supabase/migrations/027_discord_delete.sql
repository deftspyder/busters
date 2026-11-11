-- Discord: remember each bot post's message id so crew admins can delete Busters' posts from the Team tab.
alter table public.discord_log add column if not exists message_id text, add column if not exists channel_id text,
  add column if not exists preview text, add column if not exists deleted_at timestamptz;

-- discord_send (see 026) now also sets busters.dc_msg (message id:channel) and busters.dc_text for this
-- transaction; this trigger copies them onto the log row inserted right after the send.
create or replace function public.discord_log_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
declare m text := current_setting('busters.dc_msg', true);
begin
  if m is not null and m <> '' and split_part(m, ':', 1) <> '' then
    new.message_id := split_part(m, ':', 1); new.channel_id := split_part(m, ':', 2);
  end if;
  new.preview := coalesce(new.preview, nullif(current_setting('busters.dc_text', true), ''));
  return new;
end $$;
drop trigger if exists discord_log_fill on public.discord_log;
create trigger discord_log_fill before insert on public.discord_log for each row execute function public.discord_log_fill();

create or replace function public.discord_recent(p_crew uuid)
returns table (id bigint, kind text, at timestamptz, preview text)
language sql stable security definer set search_path = '' as $$
  select l.id, l.kind, l.at, l.preview from public.discord_log l
  where l.crew_id = p_crew and l.message_id is not null and l.deleted_at is null and public.can(p_crew, 'crew_admin')
  order by l.at desc limit 10;
$$;

create or replace function public.discord_delete(p_log bigint) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare l public.discord_log; d public.crew_discord; r record;
begin
  select * into l from public.discord_log where id = p_log;
  if l.id is null or l.message_id is null then raise exception 'not found'; end if;
  if not public.can(l.crew_id, 'crew_admin') then raise exception 'not allowed'; end if;
  select * into d from public.crew_discord where crew_id = l.crew_id;
  select status into r from extensions.http((
    'DELETE', 'https://discord.com/api/v10/channels/' || l.channel_id || '/messages/' || l.message_id,
    array[extensions.http_header('Authorization', 'Bot ' || d.bot_token),
          extensions.http_header('User-Agent', 'DiscordBot (https://deftspyder.github.io/busters, 1)')],
    null, null)::extensions.http_request);
  if r.status in (200, 204, 404) then update public.discord_log set deleted_at = now() where id = p_log; end if;
  return r.status;
end $$;
revoke all on function public.discord_recent(uuid), public.discord_delete(bigint) from public, anon;
grant execute on function public.discord_recent(uuid), public.discord_delete(bigint) to authenticated;
