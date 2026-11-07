-- Google bridge: a script in the crew's own Google account calls these functions
-- to sync the yearly Master Events List (read only) and the crew's Google Calendar (both ways).
-- The script proves itself with a long random token; only its hash is stored here.

create table if not exists public.bridge_tokens (
  crew_id uuid primary key references public.crews(id) on delete cascade,
  token_hash text not null,
  created_at timestamptz not null default now()
);
alter table public.bridge_tokens enable row level security;

-- Nicknames people use on the sheet, per crew.
create table if not exists public.name_aliases (
  crew_id uuid not null references public.crews(id) on delete cascade,
  alias text not null,
  person_id uuid not null references public.people(id) on delete cascade,
  primary key (crew_id, alias)
);
alter table public.name_aliases enable row level security;
create policy aliases_read on public.name_aliases for select to authenticated using (public.can(crew_id, 'manage_recruits'));

alter table public.events
  add column if not exists gcal_id text,
  add column if not exists gcal_seen_updated timestamptz,   -- calendar's "updated" stamp we last processed
  add column if not exists gcal_pushed_at timestamptz,      -- our updated_at that the calendar last received
  add column if not exists gcal_managed boolean not null default false;  -- Busters created it on the calendar, so it owns the description
create unique index if not exists events_gcal on public.events (crew_id, gcal_id) where gcal_id is not null;

create or replace function public.bridge_crew(p_token text) returns uuid
language sql stable security definer set search_path = '' as $$
  select crew_id from public.bridge_tokens
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- Do two event titles describe the same event? Shared meaningful word.
create or replace function public.same_event(a text, b text) returns boolean
language sql immutable set search_path = '' as $$
  with wa as (select distinct w from regexp_split_to_table(lower(regexp_replace(coalesce(a,''), '[^a-zA-Z0-9 ]', ' ', 'g')), '\s+') w
              where length(w) > 2 and w not in ('the','and','for','with','event','presents','lagb','ghostbusters','2026','2027','day','visit')),
       wb as (select distinct w from regexp_split_to_table(lower(regexp_replace(coalesce(b,''), '[^a-zA-Z0-9 ]', ' ', 'g')), '\s+') w
              where length(w) > 2 and w not in ('the','and','for','with','event','presents','lagb','ghostbusters','2026','2027','day','visit'))
  select exists (select 1 from wa join wb on wa.w = wb.w or (length(wa.w) > 4 and length(wb.w) > 4 and (wa.w like wb.w || '%' or wb.w like wa.w || '%')));
$$;

-- Turn a free-text sheet name into a person, or null when unsure.
create or replace function public.match_person(c uuid, raw text) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare t text; toks text[]; hit uuid; n int;
begin
  if raw is null or raw ~* '^\s*recruit' then return null; end if;
  t := lower(raw);
  t := regexp_replace(t, '\([^)]*\)', ' ', 'g');
  t := regexp_replace(t, '\s(and|w/|with|as|@|until|after|can''t|cant)\s.*$', ' ');
  t := regexp_replace(t, '[^a-z. '']', ' ', 'g');
  t := regexp_replace(t, '\m(inside|outside|maybe|pending|tentative|only)\M', ' ', 'g');
  t := trim(regexp_replace(t, '\s+', ' ', 'g'));
  if t = '' then return null; end if;
  toks := string_to_array(t, ' ');
  if cardinality(toks) > 2 then t := toks[1] || ' ' || toks[2]; toks := toks[1:2]; end if;

  select person_id into hit from public.name_aliases where crew_id = c and alias = t;
  if hit is not null then return hit; end if;
  select person_id into hit from public.name_aliases where crew_id = c and alias = toks[1] and cardinality(toks) = 1;
  if hit is not null then return hit; end if;

  -- full name or callsign
  select count(*), min(id::text)::uuid into n, hit from public.people
    where crew_id = c and status in ('active','rookie') and (lower(full_name) = t or lower(coalesce(callsign,'')) = t);
  if n = 1 then return hit; end if;
  -- first name (plus last initial when given)
  select count(*), min(id::text)::uuid into n, hit from public.people
    where crew_id = c and status in ('active','rookie') and lower(split_part(full_name, ' ', 1)) = toks[1]
      and (cardinality(toks) = 1 or lower(split_part(full_name, ' ', 2)) like replace(toks[2], '.', '') || '%');
  if n = 1 then return hit; end if;
  -- last name alone
  if cardinality(toks) = 1 then
    select count(*), min(id::text)::uuid into n, hit from public.people
      where crew_id = c and status in ('active','rookie') and lower(split_part(full_name, ' ', 2)) = toks[1];
    if n = 1 then return hit; end if;
  end if;
  return null;
end; $$;

-- ---------- sheet ----------
-- p_tabs: [{tab, title, date, end_date, call, start, wrap, schedule, location, parking, event_contact, lagb_contact, notes, conditions, attendees: [..], reserve: [..]}]
create or replace function public.bridge_sheet(p_token text, p_tabs jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare c uuid := public.bridge_crew(p_token); tz text; today date; t jsonb; e public.events; nm text; pid uuid;
  unmatched text[]; seen uuid[]; added int := 0; removed int := 0; created text[] := '{}'; linked text[] := '{}';
  ans text; note text; loc text; addr text; plid uuid; is_res boolean; nm_list text[]; n_tabs int := 0; lines text[];
begin
  if c is null then raise exception 'bad token'; end if;
  select timezone into tz from public.crews where id = c;
  today := (now() at time zone tz)::date;
  for t in select * from jsonb_array_elements(coalesce(p_tabs, '[]')) loop
    continue when nullif(t->>'date','') is null or (t->>'date')::date < today;
    n_tabs := n_tabs + 1;
    select * into e from public.events where crew_id = c and source = 'sheet' and source_key = t->>'tab';
    if e.id is null then
      -- same event already in Busters (made in the app or from the calendar)? link instead of duplicating
      select * into e from public.events where crew_id = c and event_date = (t->>'date')::date and source_key is null
        and status <> 'cancelled' and public.same_event(title, t->>'title') order by created_at limit 1;
      if e.id is not null then
        update public.events set source_key = t->>'tab', source = case when source = 'app' then source else 'sheet' end where id = e.id;
        -- source stays 'app' when made in the app; remember the tab in source_key either way
        linked := linked || e.title;
      else
        insert into public.events (crew_id, title, category, event_date, end_date, call_time, start_time, wrap_time, schedule, parking, conditions, notes, contact_name, lagb_contact, source, source_key)
        values (c, left(t->>'title', 200), null, (t->>'date')::date, nullif(t->>'end_date','')::date,
          nullif(t->>'call','')::time, nullif(t->>'start','')::time, nullif(t->>'wrap','')::time,
          nullif(t->>'schedule',''), nullif(t->>'parking',''), nullif(t->>'conditions',''), nullif(t->>'notes',''),
          nullif(split_part(coalesce(t->>'event_contact',''), E'\n', 1), ''), nullif(t->>'lagb_contact',''), 'sheet', t->>'tab')
        returning * into e;
        -- place: first line is the name; the first line that looks like a street address is the address
        lines := array_remove(array(select trim(x) from regexp_split_to_table(coalesce(t->>'location',''), E'\n') x), '');
        if cardinality(lines) > 0 then
          loc := left(lines[1], 120);
          select x into addr from unnest(lines) x where x ~ '^\d+\s' limit 1;
          if addr is not null and array_position(lines, addr) < cardinality(lines) and lines[array_position(lines, addr) + 1] ~ ',\s*[A-Z]{2}\s*\d{5}|, CA' then
            addr := addr || ', ' || lines[array_position(lines, addr) + 1];
          end if;
          if loc = addr then loc := split_part(addr, ',', 1); end if;
          insert into public.places (crew_id, name, address, kind) values (c, loc, addr, 'Event') returning id into plid;
          insert into public.event_places (event_id, crew_id, place_id, label) values (e.id, c, plid, 'Event');
        end if;
        created := created || e.title;
      end if;
    end if;

    -- sign-ups
    unmatched := '{}'; seen := '{}';
    for nm, is_res in select x, false from jsonb_array_elements_text(coalesce(t->'attendees','[]')) x
                    union all select x, true from jsonb_array_elements_text(coalesce(t->'reserve','[]')) x loop
      nm := trim(nm); continue when nm = '';
      pid := public.match_person(c, nm);
      if pid is null then unmatched := unmatched || nm; continue; end if;
      if pid = any(seen) then continue; end if;   -- listed in both columns: attendees wins
      seen := seen || pid;
      ans := case when nm ~* 'maybe|pending|tentative|\?' then 'maybe' else 'going' end;
      note := nullif(trim(regexp_replace(coalesce(substring(nm from '\(([^)]*)\)'), ''), '\s+', ' ', 'g')), '');
      if note is null and nm ~* '\m(inside|outside)\M' then note := initcap(substring(nm from '(?i)(inside|outside)')); end if;
      if note ~* '^(maybe|pending)$' then note := null; end if;
      insert into public.rsvps (event_id, person_id, crew_id, answer, spot, note, source)
        values (e.id, pid, c, ans, case when is_res then 'reserve' end, note, 'sheet')
        on conflict (event_id, person_id) do nothing;
      if found then added := added + 1; end if;
    end loop;
    -- people who took their name off the sheet (only sign-ups that came from the sheet and were never touched in the app)
    with gone as (delete from public.rsvps r where r.event_id = e.id and r.source = 'sheet' and not (r.person_id = any(seen)) returning 1)
    select removed + count(*) into removed from gone;
    update public.events set sheet_attendees = nullif(array_to_string(unmatched, E'\n'), ''), sheet_reserve = null where id = e.id;
  end loop;

  if added > 0 or removed > 0 or cardinality(created) > 0 or cardinality(linked) > 0 then
    insert into public.action_log (crew_id, action, target_type, summary, detail)
    values (c, 'sheet_import', 'crew', 'Sheet sync: ' || added || ' sign-ups added, ' || removed || ' removed'
              || case when cardinality(created) > 0 then ', new events: ' || array_to_string(created, ', ') else '' end,
            jsonb_build_object('created', created, 'linked', linked));
  end if;
  insert into public.sync_runs (crew_id, kind, summary) values (c, 'sheet_bridge', n_tabs || ' tabs, +' || added || ' -' || removed || ' sign-ups, ' || cardinality(created) || ' new events');
  return json_build_object('tabs', n_tabs, 'added', added, 'removed', removed, 'created', created, 'linked', linked);
end; $$;

-- ---------- calendar ----------
-- Local date and time to an ISO timestamp in the crew's time zone.
create or replace function public.local_iso(d date, t time, tz text) returns text
language sql immutable set search_path = '' as $$
  select to_char(((d + t) at time zone tz) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
$$;

-- p_cal: calendar events in the window: [{id, title, all_day, start, end, location, updated}]
-- Returns what the script should do on the calendar: {create: [...], update: [...], delete: [gcal ids]}
create or replace function public.bridge_calendar(p_token text, p_cal jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare c uuid := public.bridge_crew(p_token); tz text; today date; ce jsonb; e public.events; d date; st time; en time;
  upd timestamptz; first_place public.places; plid uuid; applied text[] := '{}'; made text[] := '{}'; linked text[] := '{}';
  out_create json; out_update json; out_delete json; cal_ids text[] := '{}';
begin
  if c is null then raise exception 'bad token'; end if;
  select timezone into tz from public.crews where id = c;
  today := (now() at time zone tz)::date;

  for ce in select * from jsonb_array_elements(coalesce(p_cal, '[]')) loop
    continue when coalesce(ce->>'title','') ~* 'birthday' or coalesce(ce->>'title','') ~* '^cancelled:';
    cal_ids := cal_ids || (ce->>'id');
    upd := (ce->>'updated')::timestamptz;
    if (ce->>'all_day')::boolean then d := (ce->>'start')::date; st := null; en := null;
    else d := ((ce->>'start')::timestamptz at time zone tz)::date; st := ((ce->>'start')::timestamptz at time zone tz)::time; en := ((ce->>'end')::timestamptz at time zone tz)::time; end if;
    continue when d < today - 1;

    select * into e from public.events where crew_id = c and gcal_id = ce->>'id';
    if e.id is null then
      select * into e from public.events where crew_id = c and gcal_id is null and event_date = d and status <> 'proposed'
        and public.same_event(title, ce->>'title') order by created_at limit 1;
      if e.id is not null then
        update public.events set gcal_id = ce->>'id', gcal_seen_updated = upd, gcal_pushed_at = updated_at where id = e.id;
        linked := linked || e.title;
      else
        insert into public.events (crew_id, title, event_date, call_time, wrap_time, source, source_key, gcal_id, gcal_seen_updated)
          values (c, left(ce->>'title', 200), d, st, en, 'calendar', ce->>'id', ce->>'id', upd) returning * into e;
        update public.events set gcal_pushed_at = updated_at where id = e.id;
        if coalesce(trim(ce->>'location'), '') <> '' then
          insert into public.places (crew_id, name, address, kind) values (c, split_part(trim(ce->>'location'), ',', 1), trim(ce->>'location'), 'Event') returning id into plid;
          insert into public.event_places (event_id, crew_id, place_id, label) values (e.id, c, plid, 'Event');
        end if;
        made := made || e.title;
      end if;
    elsif upd > coalesce(e.gcal_seen_updated, '-infinity') + interval '2 seconds' then
      -- someone changed it in Google Calendar since we last looked
      if e.updated_at <= coalesce(e.gcal_pushed_at, e.updated_at) + interval '2 seconds' then
        update public.events set
          title = left(ce->>'title', 200), event_date = d,
          call_time = case when st is null then call_time when call_time is not null or start_time is null then st else call_time end,
          start_time = case when st is null then start_time when call_time is null and start_time is not null then st else start_time end,
          wrap_time = coalesce(en, wrap_time),
          gcal_seen_updated = upd, updated_at = now()
        where id = e.id returning * into e;
        update public.events set gcal_pushed_at = updated_at where id = e.id;
        if coalesce(trim(ce->>'location'), '') <> '' then
          select pl.* into first_place from public.event_places ep join public.places pl on pl.id = ep.place_id where ep.event_id = e.id order by ep.sort limit 1;
          if first_place.id is null then
            insert into public.places (crew_id, name, address, kind) values (c, split_part(trim(ce->>'location'), ',', 1), trim(ce->>'location'), 'Event') returning id into plid;
            insert into public.event_places (event_id, crew_id, place_id, label) values (e.id, c, plid, 'Event');
          elsif lower(coalesce(first_place.address, first_place.name)) <> lower(trim(ce->>'location')) and lower(first_place.name) <> lower(trim(ce->>'location')) then
            insert into public.places (crew_id, name, address, kind) values (c, split_part(trim(ce->>'location'), ',', 1), trim(ce->>'location'), 'Event') returning id into plid;
            update public.event_places set place_id = plid where event_id = e.id and place_id = first_place.id;
          end if;
        end if;
        applied := applied || e.title;
      else
        -- changed in both places since the last sync: Busters wins, the calendar gets overwritten below
        update public.events set gcal_seen_updated = upd where id = e.id;
      end if;
    end if;
  end loop;

  if cardinality(applied) + cardinality(made) + cardinality(linked) > 0 then
    insert into public.action_log (crew_id, action, target_type, summary, detail)
    values (c, 'calendar_in', 'crew', 'Google Calendar: '
      || concat_ws('; ', case when cardinality(made) > 0 then 'added ' || array_to_string(made, ', ') end,
                         case when cardinality(applied) > 0 then 'changes from the calendar applied to ' || array_to_string(applied, ', ') end,
                         case when cardinality(linked) > 0 then 'matched ' || array_to_string(linked, ', ') end),
      jsonb_build_object('made', made, 'applied', applied, 'linked', linked));
  end if;

  -- what the calendar needs from Busters
  with ev as (
    select e2.*, (select coalesce(nullif(pl.address, ''), pl.name) from public.event_places ep join public.places pl on pl.id = ep.place_id where ep.event_id = e2.id order by ep.sort limit 1) as loc,
      (select p.full_name from public.people p where p.id = e2.poc_id) as poc_name
    from public.events e2
    where e2.crew_id = c and e2.status in ('scheduled','cancelled') and coalesce(e2.end_date, e2.event_date) >= today - 1
  ), shaped as (
    select ev.id, ev.gcal_id, ev.updated_at, ev.gcal_managed as managed,
      case when ev.status = 'cancelled' then 'CANCELLED: ' else '' end || ev.title as title,
      coalesce(ev.call_time, ev.start_time) is null as all_day,
      case when coalesce(ev.call_time, ev.start_time) is null then to_char(ev.event_date, 'YYYY-MM-DD')
           else public.local_iso(ev.event_date, coalesce(ev.call_time, ev.start_time), tz) end as start,
      case when coalesce(ev.call_time, ev.start_time) is null then to_char(coalesce(ev.end_date, ev.event_date) + 1, 'YYYY-MM-DD')
           else public.local_iso(coalesce(ev.end_date, ev.event_date) + case when coalesce(ev.wrap_time, coalesce(ev.call_time, ev.start_time) + interval '2 hours') < coalesce(ev.call_time, ev.start_time) then 1 else 0 end,
                                 coalesce(ev.wrap_time, (coalesce(ev.call_time, ev.start_time) + interval '2 hours')::time), tz) end as "end",
      ev.loc as location,
      concat_ws(E'\n',
        case when ev.call_time is not null then 'Call: ' || to_char(ev.call_time, 'FMHH12:MI AM') end,
        case when ev.start_time is not null then 'Start: ' || to_char(ev.start_time, 'FMHH12:MI AM') end,
        case when ev.wrap_time is not null then 'Wrap: ' || to_char(ev.wrap_time, 'FMHH12:MI AM') end,
        case when ev.poc_name is not null then 'Point of contact: ' || ev.poc_name end,
        '', 'Sign up and details in Busters: https://deftspyder.github.io/busters/#event/' || ev.id) as description
    from ev
  )
  select coalesce(json_agg(row_to_json(s)) filter (where s.gcal_id is null), '[]'),
         coalesce(json_agg(row_to_json(s)) filter (where s.gcal_id is not null and (e3.gcal_pushed_at is null or e3.updated_at > e3.gcal_pushed_at + interval '2 seconds')), '[]')
    into out_create, out_update
  from shaped s join public.events e3 on e3.id = s.id;

  select coalesce(json_agg(l.detail->>'gcal_id'), '[]') into out_delete from public.action_log l
    where l.crew_id = c and l.action = 'event_deleted' and l.at > now() - interval '30 days'
      and l.detail->>'gcal_id' is not null and not coalesce((l.detail->>'gcal_removed')::boolean, false);

  insert into public.sync_runs (crew_id, kind, summary) values (c, 'calendar_bridge',
    'in: ' || cardinality(made) || ' new, ' || cardinality(applied) || ' changed, ' || cardinality(linked) || ' matched; out: '
    || json_array_length(out_create) || ' to create, ' || json_array_length(out_update) || ' to update, ' || json_array_length(out_delete) || ' to delete');
  return json_build_object('create', out_create, 'update', out_update, 'delete', out_delete);
end; $$;

-- The script reports back what it did on the calendar.
-- p_done: [{event_id, gcal_id, updated_at (the Busters updated_at it pushed), cal_updated}], p_deleted: [gcal ids removed]
create or replace function public.bridge_calendar_done(p_token text, p_done jsonb, p_deleted jsonb default '[]')
returns void language plpgsql security definer set search_path = '' as $$
declare c uuid := public.bridge_crew(p_token); x jsonb;
begin
  if c is null then raise exception 'bad token'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_done, '[]')) loop
    update public.events set gcal_id = x->>'gcal_id',
      gcal_managed = gcal_managed or coalesce((x->>'created')::boolean, false),
      gcal_pushed_at = greatest(coalesce(gcal_pushed_at, '-infinity'), (x->>'updated_at')::timestamptz),
      gcal_seen_updated = greatest(coalesce(gcal_seen_updated, '-infinity'), (x->>'cal_updated')::timestamptz)
    where id = (x->>'event_id')::uuid and crew_id = c;
  end loop;
  update public.action_log set detail = detail || '{"gcal_removed": true}'
    where crew_id = c and action = 'event_deleted' and detail->>'gcal_id' in (select jsonb_array_elements_text(coalesce(p_deleted, '[]')));
end; $$;

-- Health check for the Team tab: when each bridge last ran.
create or replace function public.bridge_status(p_crew uuid)
returns json language sql stable security definer set search_path = '' as $$
  select case when public.can(p_crew, 'crew_admin') then json_build_object(
    'sheet', (select json_build_object('at', ran_at, 'summary', summary) from public.sync_runs where crew_id = p_crew and kind = 'sheet_bridge' order by ran_at desc limit 1),
    'calendar', (select json_build_object('at', ran_at, 'summary', summary) from public.sync_runs where crew_id = p_crew and kind = 'calendar_bridge' order by ran_at desc limit 1)) end;
$$;

revoke execute on function public.bridge_crew(text), public.match_person(uuid, text) from public, anon, authenticated;
grant execute on function public.bridge_sheet(text, jsonb), public.bridge_calendar(text, jsonb), public.bridge_calendar_done(text, jsonb, jsonb) to anon, authenticated;
grant execute on function public.bridge_status(uuid) to authenticated;

-- Applied afterwards on the live project (see Supabase migration history for exact text):
--   match_person: also strips [brackets], "w/", "+", "&", accents; skips "Special guests" and "BUSTERS AVAILABLE" lines.
--   bridge_sheet: Postgres word boundary is \y (not \b) in the address check; reuses a saved place with the
--   same name or address instead of making a duplicate; a one-line address becomes both name and address.
