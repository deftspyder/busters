-- Sheet bridge fills gaps on every hourly run, not just when an event is first imported. Until now a tab was read
-- fully only once: later additions on the sheet (contacts, times, parking, notes) never reached Busters, and only
-- the first line of the Event Contact cell was kept, with any phone number left inside the name.
-- Now each run fills only fields that are still empty in Busters (anything typed in the app always wins), splits the
-- contact's phone and email out of the cell, and sets the point of contact from LAGB Contact when it names a member
-- who can be one. Each tab's latest sheet data is kept in sheet_tabs so it can be checked against Busters.

create table if not exists public.sheet_tabs (
  crew_id uuid not null references public.crews(id) on delete cascade,
  tab text not null,
  event_id uuid references public.events(id) on delete set null,
  data jsonb not null,
  seen_at timestamptz not null default now(),
  primary key (crew_id, tab)
);
alter table public.sheet_tabs enable row level security;  -- no policies: database only

-- "Joe Mejia (562) 665-0439" or "Name\nname@x.org\n310-555-0100" to name, phone, email.
create or replace function public.split_contact(p text, out name text, out phone text, out email text)
language sql immutable set search_path to '' as $$
  select nullif(btrim(regexp_replace(regexp_replace(regexp_replace(split_part(coalesce(p, ''), E'\n', 1),
           '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '', 'g'),
           '\+?1?[\s.-]*\(?\d{3}\)?[\s.-]*\d{3}[\s.-]*\d{4}', '', 'g'),
           '[\s,;:|/-]+$', ''), ' ,;:-'), ''),
         substring(coalesce(p, '') from '\(?\d{3}\)?[\s.-]*\d{3}[\s.-]*\d{4}'),
         substring(coalesce(p, '') from '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
$$;

create or replace function public.sheet_fill(p_event uuid, t jsonb) returns void
language plpgsql security definer set search_path to '' as $$
declare e public.events; sc record; first_line text; pid uuid;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or e.status = 'cancelled' then return; end if;
  insert into public.sheet_tabs (crew_id, tab, event_id, data, seen_at) values (e.crew_id, t->>'tab', e.id, t, now())
    on conflict (crew_id, tab) do update set event_id = excluded.event_id, data = excluded.data, seen_at = now();
  first_line := nullif(btrim(split_part(coalesce(t->>'event_contact', ''), E'\n', 1)), '');
  select * into sc from public.split_contact(t->>'event_contact');
  update public.events set
    contact_name = case when contact_name is null or contact_name = first_line then coalesce(sc.name, contact_name) else contact_name end,
    contact_phone = coalesce(contact_phone, sc.phone),
    contact_email = coalesce(contact_email, sc.email),
    start_time = coalesce(start_time, nullif(t->>'start', '')::time),
    wrap_time = coalesce(wrap_time, nullif(t->>'wrap', '')::time),
    call_time = coalesce(call_time, nullif(t->>'call', '')::time),
    schedule = coalesce(schedule, nullif(t->>'schedule', '')),
    parking = coalesce(parking, nullif(t->>'parking', '')),
    notes = coalesce(notes, nullif(t->>'notes', '')),
    conditions = coalesce(conditions, nullif(t->>'conditions', '')),
    lagb_contact = coalesce(nullif(t->>'lagb_contact', ''), lagb_contact)
  where id = e.id;
  if e.poc_id is null and coalesce(t->>'lagb_contact', '') !~* '^\s*(pending|tbd|none|n/?a)?\s*$' then
    pid := public.match_person(e.crew_id, split_part(t->>'lagb_contact', E'\n', 1));
    if pid is not null and exists (select 1 from public.people p where p.id = pid and p.status in ('active', 'rookie')
                                   and ('poc' = any(p.abilities) or 'crew_admin' = any(p.abilities))) then
      update public.events set poc_id = pid where id = e.id;
    end if;
  end if;
end $$;
revoke all on function public.sheet_fill(uuid, jsonb) from public, anon, authenticated;

-- Call it for every tab, new or already imported.
do $$
declare d text := pg_get_functiondef('public.bridge_sheet(text,jsonb)'::regprocedure);
  f text := $x$    unmatched := '{}'; seen := '{}';$x$;
begin
  if position('sheet_fill' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'bridge_sheet: attendee loop start not found once'; end if;
  execute replace(d, f, $x$    perform public.sheet_fill(e.id, t);
$x$ || f);
end $$;

-- Tidy what is already there: pull phone numbers and emails out of contact names.
update public.events set contact_name = coalesce((public.split_contact(contact_name)).name, contact_name),
  contact_phone = coalesce(contact_phone, (public.split_contact(contact_name)).phone),
  contact_email = coalesce(contact_email, (public.split_contact(contact_name)).email)
where status <> 'cancelled' and ((public.split_contact(contact_name)).phone is not null or (public.split_contact(contact_name)).email is not null);

-- One-time catch-up for upcoming events already in Busters (LAGB, Nov 12): point of contact from LAGB Contact, and
-- the walkers' call times the sheet lists as a second call.
update public.events e set poc_id = p.id
from public.people p
where e.poc_id is null and e.status = 'scheduled' and coalesce(e.end_date, e.event_date) >= current_date
  and e.lagb_contact !~* '^\s*(pending|tbd|none|n/?a)?\s*$'
  and p.id = public.match_person(e.crew_id, split_part(e.lagb_contact, E'\n', 1))
  and p.status in ('active', 'rookie') and ('poc' = any(p.abilities) or 'crew_admin' = any(p.abilities));

update public.events set extra_times = '[{"label":"Walkers call","time":"17:30"}]'
where source_key = '11/29_Hollywood Xmas Parade' and extra_times = '[]'::jsonb;
update public.events set extra_times = '[{"label":"Walkers call","time":"09:00"}]'
where source_key = '12/XX_Uptown Whittier Christmas Parade 2026' and extra_times = '[]'::jsonb;
