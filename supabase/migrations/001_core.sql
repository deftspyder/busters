-- Busters core schema: crews, people, abilities, events, places, RSVPs, action log.
-- Every row carries crew_id; row level security keeps each crew's data to its own members.

create extension if not exists pgcrypto with schema extensions;

-- ---------- crews and admins ----------
create table public.crews (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  short_name text not null,
  timezone text not null default 'America/Los_Angeles',
  give_back_goal numeric,
  give_back_name text,            -- the crew's name on the Give Back feed, e.g. 'Los Angeles Ghostbusters'
  created_at timestamptz not null default now()
);

create table public.app_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  maps_app text not null default 'google' check (maps_app in ('google','apple','waze')),
  created_at timestamptz not null default now()
);

-- ---------- people ----------
-- One row per person in a crew: members, rookies, retired members, and people waiting for approval.
-- A row can exist before the person signs in (the pre-approved list); user_id links it once they do.
create table public.people (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references public.crews(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  full_name text not null,
  callsign text,
  title text,                      -- crew role as the crew says it, e.g. 'Personnel Manager'
  status text not null default 'active' check (status in ('pending','active','rookie','retired','declined','removed')),
  abilities text[] not null default '{}',
  member_since date,
  rookie_since date,
  eligible_date date,
  city text,                        -- opt-in, city level only
  show_on_map boolean not null default false,
  approved_by uuid references public.people(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (crew_id, user_id)
);
create index on public.people (crew_id);
create index on public.people (user_id);

-- Contact details: only the person, Personnel and the crew admin can read these.
create table public.people_private (
  person_id uuid primary key references public.people(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  email text,
  phone text,
  discord text,
  instagram text,
  birthday date
);
create unique index people_private_email on public.people_private (crew_id, lower(email)) where email is not null;

create table public.dues (
  person_id uuid not null references public.people(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  year int not null,
  status text not null,             -- 'paid', 'waived', 'unpaid' or free text from the old sheet
  updated_at timestamptz not null default now(),
  primary key (person_id, year)
);

-- ---------- places and events ----------
create table public.places (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references public.crews(id) on delete cascade,
  name text not null,
  address text,
  kind text,                        -- suggested label: Event, Parking, Staging, Meeting point...
  notes text,
  retired_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.places (crew_id);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references public.crews(id) on delete cascade,
  title text not null,
  category text,                    -- Hospital, Charity, Community, Parade, Convention, Run/Walk, Private, Social
  status text not null default 'scheduled' check (status in ('proposed','scheduled','cancelled','closed')),
  event_date date not null,
  end_date date,
  call_time time,
  start_time time,
  wrap_time time,
  schedule text,
  parking text,
  conditions text,                  -- indoors/outdoors, weather, uniform notes
  notes text,
  contact_name text,
  contact_phone text,
  contact_email text,
  poc_id uuid references public.people(id) on delete set null,
  min_busters int,
  goal_busters int,
  max_busters int,                  -- set = limited event
  source text not null default 'app',  -- app, sheet, calendar, form, member
  source_key text,                  -- id in the source (calendar event id, sheet tab name)
  proposed_by uuid references public.people(id) on delete set null,
  created_by uuid references public.people(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.people(id) on delete set null
);
create index on public.events (crew_id, event_date);
create unique index events_source on public.events (crew_id, source, source_key) where source_key is not null;

create table public.event_places (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  place_id uuid not null references public.places(id),
  label text not null default 'Event',
  sort int not null default 0
);
create index on public.event_places (event_id);

create table public.rsvps (
  event_id uuid not null references public.events(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  answer text not null check (answer in ('going','maybe','no')),
  ride text check (ride in ('own','driving','need')),
  seats int,
  note text,
  spot text check (spot in ('in','reserve')),   -- limited events only, set by the events team
  updated_at timestamptz not null default now(),
  primary key (event_id, person_id)
);
create index on public.rsvps (person_id);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references public.crews(id) on delete cascade,
  author_id uuid references public.people(id) on delete set null,
  body text not null check (length(body) between 1 and 2000),
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.action_log (
  id bigint generated always as identity primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  actor_id uuid references public.people(id) on delete set null,
  action text not null,
  target_type text,
  target_id uuid,
  summary text,
  detail jsonb,
  at timestamptz not null default now()
);
create index on public.action_log (crew_id, at desc);

-- ---------- helpers ----------
create or replace function public.is_app_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.app_admins a where a.user_id = (select auth.uid()));
$$;

-- The signed-in user's person row in a crew, only while they are let in (active or rookie).
create or replace function public.me(c uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select p.id from public.people p
  where p.crew_id = c and p.user_id = (select auth.uid()) and p.status in ('active','rookie') limit 1;
$$;

create or replace function public.in_crew(c uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.me(c) is not null or public.is_app_admin();
$$;

-- Ability check. 'crew_admin' and the app admin can do everything.
create or replace function public.can(c uuid, ability text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_app_admin() or exists (
    select 1 from public.people p
    where p.crew_id = c and p.user_id = (select auth.uid()) and p.status in ('active','rookie')
      and (ability = any(p.abilities) or 'crew_admin' = any(p.abilities))
  );
$$;

create or replace function public.log_action(c uuid, act text, ttype text, tid uuid, summ text, det jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.action_log (crew_id, actor_id, action, target_type, target_id, summary, detail)
  values (c, public.me(c), act, ttype, tid, summ, det);
$$;
revoke execute on function public.log_action(uuid, text, text, uuid, text, jsonb) from public, anon, authenticated;

-- New auth user: make a profile.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, left(coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)), 60))
  on conflict (id) do nothing;
  return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- row level security ----------
alter table public.crews enable row level security;
alter table public.app_admins enable row level security;
alter table public.profiles enable row level security;
alter table public.people enable row level security;
alter table public.people_private enable row level security;
alter table public.dues enable row level security;
alter table public.places enable row level security;
alter table public.events enable row level security;
alter table public.event_places enable row level security;
alter table public.rsvps enable row level security;
alter table public.announcements enable row level security;
alter table public.action_log enable row level security;

create policy crews_read on public.crews for select to authenticated using (public.in_crew(id));
create policy app_admins_self on public.app_admins for select to authenticated using (user_id = (select auth.uid()));
create policy profiles_self on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_self_upd on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Members see the roster (no contact details live here). Your own row is always visible, even while pending.
create policy people_read on public.people for select to authenticated
  using (public.in_crew(crew_id) and status <> 'declined' or user_id = (select auth.uid()));

create policy private_read on public.people_private for select to authenticated
  using (public.can(crew_id, 'manage_recruits')
         or exists (select 1 from public.people p where p.id = person_id and p.user_id = (select auth.uid())));

create policy dues_read on public.dues for select to authenticated
  using (public.can(crew_id, 'manage_recruits')
         or exists (select 1 from public.people p where p.id = person_id and p.user_id = (select auth.uid())));

create policy places_read on public.places for select to authenticated using (public.in_crew(crew_id));

-- Proposed events are seen by whoever proposed them and by people who manage proposals.
create policy events_read on public.events for select to authenticated
  using (public.in_crew(crew_id) and (status <> 'proposed' or public.can(crew_id, 'manage_proposals') or proposed_by = public.me(crew_id)));

create policy event_places_read on public.event_places for select to authenticated
  using (exists (select 1 from public.events e where e.id = event_id));   -- inherits the events policy

create policy rsvps_read on public.rsvps for select to authenticated using (public.in_crew(crew_id));
create policy announcements_read on public.announcements for select to authenticated using (public.in_crew(crew_id));
create policy log_read on public.action_log for select to authenticated using (public.can(crew_id, 'view_log'));

-- All writes go through the functions below, which check abilities and write the action log.
