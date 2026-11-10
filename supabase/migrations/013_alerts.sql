-- Phone alerts: short-staffed events (each person picks how many days ahead) and a 48-hour last call.
-- Sent by the busters-alerts edge function, run every 15 minutes by pg_cron.

alter table public.profiles
  add column if not exists alert_short boolean not null default true,
  add column if not exists alert_days int not null default 7 check (alert_days between 1 and 30),
  add column if not exists alert_lastcall boolean not null default true;

-- One row per phone or browser that turned alerts on.
create table if not exists public.push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);
alter table public.push_subs enable row level security;
create policy push_subs_own_select on public.push_subs for select to authenticated using (user_id = (select auth.uid()));
create policy push_subs_own_insert on public.push_subs for insert to authenticated with check (user_id = (select auth.uid()));
create policy push_subs_own_update on public.push_subs for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy push_subs_own_delete on public.push_subs for delete to authenticated using (user_id = (select auth.uid()));
grant select, insert, update, delete on public.push_subs to authenticated;

-- Each alert goes to a person once per event and kind.
create table if not exists public.alert_log (
  person_id uuid not null references public.people(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  kind text not null check (kind in ('short','lastcall')),
  sent_at timestamptz not null default now(),
  primary key (person_id, event_id, kind)
);
alter table public.alert_log enable row level security;

-- Push keys. The edge function creates them on its first run; nobody else reads the private key.
create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  vapid_public text not null,
  vapid_private text not null,
  created_at timestamptz not null default now()
);
alter table public.push_config enable row level security;

create or replace function public.push_public_key() returns text
language sql stable security definer set search_path = '' as $$
  select vapid_public from public.push_config where id = 1;
$$;

create or replace function public.set_alert_prefs(p_short boolean, p_days int, p_lastcall boolean)
returns void language sql security definer set search_path = '' as $$
  update public.profiles
     set alert_short = coalesce(p_short, alert_short),
         alert_days = least(30, greatest(1, coalesce(p_days, alert_days))),
         alert_lastcall = coalesce(p_lastcall, alert_lastcall)
   where id = (select auth.uid());
$$;

-- What is due right now. Service role only.
create or replace function public.alert_plan()
returns table (user_id uuid, person_id uuid, event_id uuid, kind text, title text, body text, url text)
language sql stable security definer set search_path = '' as $$
  with ev as (
    select e.id, e.crew_id, e.title, e.event_date, e.min_busters, e.going,
           ((e.event_date + coalesce(e.call_time, e.start_time, time '12:00')) at time zone coalesce(c.timezone, 'America/Los_Angeles')) as starts,
           (e.event_date - (now() at time zone coalesce(c.timezone, 'America/Los_Angeles'))::date) as days_until,
           c.timezone
    from public.events_full e join public.crews c on c.id = e.crew_id
    where e.status = 'scheduled' and e.min_busters is not null and e.going < e.min_busters
      and e.event_date >= (now() at time zone 'America/Los_Angeles')::date - 1
  ),
  who as (
    select ev.*, p.id as pid, p.user_id as uid, pr.alert_short, pr.alert_days, pr.alert_lastcall
    from ev
    join public.people p on p.crew_id = ev.crew_id and p.status in ('active','rookie') and p.user_id is not null
    join public.profiles pr on pr.id = p.user_id
    where not exists (select 1 from public.rsvps r where r.event_id = ev.id and r.person_id = p.id and r.answer in ('going','no'))
      and ev.starts > now()
  ),
  due as (
    select w.*, 'lastcall'::text as k from who w
    where w.alert_lastcall and w.starts <= now() + interval '48 hours'
    union all
    select w.*, 'short'::text from who w
    where w.alert_short and w.days_until <= w.alert_days and w.starts > now() + interval '48 hours'
  )
  select d.uid, d.pid, d.id, d.k,
         case d.k when 'lastcall' then 'Last call: ' || d.title else 'Short on Busters: ' || d.title end,
         to_char(d.starts at time zone coalesce(d.timezone, 'America/Los_Angeles'), 'Dy Mon FMDD, FMHH12:MI AM')
           || ' · ' || d.going || ' of ' || d.min_busters
           || case d.k when 'lastcall' then '. Still need ' || (d.min_busters - d.going) || ' more. Can you make it?' else '. Can you make it?' end,
         'https://deftspyder.github.io/busters/#event/' || d.id
  from due d
  where not exists (select 1 from public.alert_log l where l.person_id = d.pid and l.event_id = d.id and l.kind = d.k);
$$;

-- my_session also returns the alert settings.
create or replace function public.my_session(p_crew uuid)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'app_admin', public.is_app_admin(),
    'person', (select row_to_json(x) from (select p.id, p.full_name, p.callsign, p.title, p.status, p.abilities, p.city, p.show_on_map, p.member_since
               from public.people p where p.crew_id = p_crew and p.user_id = (select auth.uid())) x),
    'private', (select row_to_json(x) from (select pp.phone, pp.discord, pp.instagram, pp.birthday, pp.email
               from public.people_private pp join public.people p on p.id = pp.person_id where p.crew_id = p_crew and p.user_id = (select auth.uid())) x),
    'dues', (select coalesce(json_object_agg(d.year, d.status), '{}') from public.dues d join public.people p on p.id = d.person_id
               where p.crew_id = p_crew and p.user_id = (select auth.uid())),
    'profile', (select row_to_json(x) from (select pr.display_name, pr.maps_app, pr.alert_short, pr.alert_days, pr.alert_lastcall
               from public.profiles pr where pr.id = (select auth.uid())) x)
  );
$$;

revoke all on function public.alert_plan() from public, anon, authenticated;
revoke all on function public.push_public_key(), public.set_alert_prefs(boolean, int, boolean) from public, anon;
grant execute on function public.push_public_key(), public.set_alert_prefs(boolean, int, boolean) to authenticated;
