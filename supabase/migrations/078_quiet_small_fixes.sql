-- Discord "Event updated" posts skip changes that aren't news (Nov 17).
-- Covers every source (app editor, Google Calendar sync, Master Events List sync), since it runs where
-- changes are posted, not where they're made.
--  1. No real change: old and new match once case, spaces and punctuation are ignored
--     (the sheet sync rewriting a place with the same name and address, like Tonga Hut on Nov 17).
--  2. Small typo fixes to text (title, parking, place names and addresses): 3 letters or fewer,
--     and no more than a fifth of the text. A real rename or a new venue still posts.
-- Date, time, cancelled and back on changes always post as before. The Discord card still updates in
-- place with the fix, just without a new post.
create extension if not exists fuzzystrmatch with schema extensions;

create or replace function public.dc_norm(t text) returns text
language sql immutable set search_path = '' as $$
  select nullif(regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '', 'g'), '');
$$;

create or replace function public.dc_trivial(p_field text, p_old text, p_new text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare a text := public.dc_norm(p_old); b text := public.dc_norm(p_new); d int; len int;
begin
  if a is not distinct from b then return true; end if;
  if a is null or b is null then return false; end if;                 -- added or removed is news
  if not (p_field in ('title', 'parking') or p_field like 'place:%') then return false; end if;
  if regexp_replace(a, '[^0-9]', '', 'g') <> regexp_replace(b, '[^0-9]', '', 'g') then return false; end if;  -- numbers changed (street number, lot): news
  len := least(length(a), length(b));
  if length(a) <= 255 and length(b) <= 255 then
    d := extensions.levenshtein(a, b);
  else
    if abs(length(a) - length(b)) > 3 then return false; end if;
    d := greatest(extensions.levenshtein(left(a, 255), left(b, 255)), extensions.levenshtein(right(a, 255), right(b, 255)));
  end if;
  return d <= 3 and d * 5 <= len;
end $$;

create or replace function public.discord_post_changes() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; st int; n int := 0; lines text; kind text; cancelled text;
begin
  -- Not news: close these without posting.
  update public.discord_changes set posted_at = now()
  where posted_at is null and public.dc_trivial(field, old_val, new_val);

  for r in
    select e.id, e.crew_id, e.status from public.discord_changes c
    join public.events e on e.id = c.event_id
    join public.crew_discord d on d.crew_id = e.crew_id
    where c.posted_at is null and d.post_changes and d.bot_token is not null and d.channel_id is not null
      and not public.dc_quiet(d.quiet_from, d.quiet_to)
    group by e.id having max(c.at) < now() - interval '10 minutes'
  loop
    cancelled := null;
    select new_val into cancelled from public.discord_changes where event_id = r.id and field = 'status' and posted_at is null and old_val is distinct from new_val;
    lines := public.dc_change_lines(r.id);
    kind := case when cancelled = 'cancelled' and r.status = 'cancelled' then 'cancelled'
                 when cancelled = 'scheduled' and r.status = 'scheduled' then 'backon'
                 when lines is not null and r.status = 'scheduled' then 'changes' end;
    if kind is not null then
      st := public.dc_bump(r.id, 'changes', kind, lines);
      n := n + 1;
    end if;
    update public.discord_changes set posted_at = now() where event_id = r.id and posted_at is null;
  end loop;
  return n;
end $$;

revoke all on function public.discord_post_changes(), public.dc_trivial(text, text, text), public.dc_norm(text) from public, anon, authenticated;
