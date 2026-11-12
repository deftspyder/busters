-- An event's Discord card always shows the event's latest info. Any change (times, places, counts, flyer, details)
-- edits the card in place: no new post and no pings. Saving in the app refreshes it right away, and the 15-minute
-- run catches anything else (for example new sign-ups). Cards also list any extra times (Meet-up, Photo op...).

alter table public.discord_log add column if not exists shown_hash text;

-- Extra times on the card, in time order, under the date line.
do $$
declare d text := pg_get_functiondef('public.dc_embed(uuid,text,text)'::regprocedure);
  f text := $x$descr := whenl || coalesce(E'\n' || counts, '')$x$;
begin
  if position('extra_times' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'dc_embed: descr line not found once'; end if;
  execute replace(d, f, $x$descr := whenl
    || coalesce(E'\n🕒 ' || (select string_agg((x->>'label') || ' ' || public.dc_t((x->>'time')::time), ' · ' order by x->>'time')
                             from jsonb_array_elements(coalesce(e.extra_times, '[]'::jsonb)) x where coalesce(x->>'time', '') <> ''), '')
    || coalesce(E'\n' || counts, '')$x$);
end $$;

-- The card's embed: the event details plus the flyer as a thumbnail.
create or replace function public.dc_card_embed(p_event uuid, p_kind text, p_extra text) returns jsonb
language sql stable security definer set search_path to '' as $$
  select public.dc_embed(p_event, p_kind, p_extra) || coalesce((select jsonb_build_object('thumbnail', jsonb_build_object('url',
      'https://fwptdvoifkfljblyziva.supabase.co/storage/v1/object/public/event-files/' || f.path))
    from public.event_files f where f.event_id = p_event and f.is_flyer and f.mime like 'image/%' limit 1), '{}'::jsonb);
$$;

create or replace function public.dc_send_event(p_event uuid, p_kind text, p_extra text) returns integer
language plpgsql security definer set search_path to '' as $$
declare e public.events; p jsonb;
begin
  select * into e from public.events where id = p_event;
  p := jsonb_build_object('embeds', jsonb_build_array(public.dc_card_embed(p_event, p_kind, p_extra)));
  if e.status = 'scheduled' and p_kind not in ('photos', 'cancelled') and e.event_date >= (now() at time zone 'America/Los_Angeles')::date then
    p := p || jsonb_build_object('components', public.dc_buttons(p_event));
  end if;
  return public.discord_send_payload(e.crew_id, p, e.title);
end $$;

-- Bring an event's live cards up to date, editing only the ones whose content changed.
create or replace function public.dc_refresh_cards(p_event uuid) returns integer
language plpgsql security definer set search_path to '' as $$
declare r record; body jsonb; h text; st int; n int := 0; g int;
begin
  select going into g from public.events_full where id = p_event;
  for r in select l.id, l.crew_id, l.channel_id, l.message_id, l.card_kind, l.card_extra, l.shown_hash from public.discord_log l
           where l.event_id = p_event and l.message_id is not null and l.deleted_at is null and l.card_kind is not null
             and l.kind not in ('photos', 'test') loop
    body := jsonb_build_object('embeds', jsonb_build_array(public.dc_card_embed(p_event, r.card_kind, r.card_extra)));
    h := md5(body::text);
    continue when h = r.shown_hash;
    st := public.dc_http(r.crew_id, 'PATCH', '/channels/' || r.channel_id || '/messages/' || r.message_id, body);
    if st between 200 and 299 then update public.discord_log set shown_hash = h, going_shown = g where id = r.id; n := n + 1;
    elsif st = 404 then update public.discord_log set deleted_at = now() where id = r.id; end if;
  end loop;
  return n;
end $$;
revoke all on function public.dc_refresh_cards(uuid) from public, anon, authenticated;

-- The app calls this after saving an event or changing its attachments.
create or replace function public.refresh_event_card(p_event uuid) returns integer
language plpgsql security definer set search_path to '' as $$
begin
  if not public.can_edit_event(p_event) then raise exception 'not allowed'; end if;
  return public.dc_refresh_cards(p_event);
end $$;
grant execute on function public.refresh_event_card(uuid) to authenticated;

-- discord_run: refresh every upcoming event's cards (it used to refresh only when the Going count changed).
do $$
declare d text := pg_get_functiondef('public.discord_run()'::regprocedure); a int; b int; blk text;
begin
  if position('dc_refresh_cards' in d) > 0 then return; end if;
  a := strpos(d, '    for r in' || E'\n' || '      select l.id, l.channel_id, l.message_id, l.event_id, l.card_kind, l.card_extra, ef.going');
  if a = 0 then raise exception 'discord_run: card refresh loop not found'; end if;
  b := strpos(substr(d, a), 'end loop;');
  blk := substr(d, a, b + length('end loop;') - 1);
  execute replace(d, blk, $x$    for r in select distinct l.event_id from public.discord_log l join public.events e on e.id = l.event_id
             where l.crew_id = d.crew_id and l.message_id is not null and l.deleted_at is null and l.card_kind is not null
               and l.kind not in ('photos', 'test') and coalesce(e.end_date, e.event_date) >= today loop
      n := n + public.dc_refresh_cards(r.event_id);
    end loop;$x$);
end $$;
