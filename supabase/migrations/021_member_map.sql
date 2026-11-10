-- Member map: opted-in members at city level only (never street addresses).
-- Cities are looked up once on OpenStreetMap's Nominatim and cached here.
create table if not exists public.city_geo (
  city_key text primary key,          -- lower(trim(city))
  lat double precision,
  lng double precision,
  label text,
  looked_up_at timestamptz not null default now()
);
alter table public.city_geo enable row level security;

-- Looks up a few uncached cities per run (Nominatim allows about 1 request a second).
create or replace function public.geocode_cities() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c text; r record; j jsonb; n int := 0;
begin
  for c in
    select distinct lower(trim(p.city)) from public.people p
    where p.city is not null and trim(p.city) <> '' and p.show_on_map
      and not exists (select 1 from public.city_geo g where g.city_key = lower(trim(p.city)))
    limit 10
  loop
    begin
      select status, content into r from extensions.http((
        'GET',
        'https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=us&q=' || extensions.urlencode(c),
        array[extensions.http_header('User-Agent', 'Busters crew app (deftspyder.github.io/busters)')],
        null, null)::extensions.http_request);
      if r.status = 200 then
        j := r.content::jsonb;
        insert into public.city_geo (city_key, lat, lng, label)
        values (c, (j->0->>'lat')::float8, (j->0->>'lon')::float8, j->0->>'display_name')
        on conflict (city_key) do update set lat = excluded.lat, lng = excluded.lng, label = excluded.label, looked_up_at = now();
        n := n + 1;
      end if;
      perform pg_sleep(1.1);
    exception when others then null;
    end;
  end loop;
  return 'looked up ' || n;
end $$;
revoke all on function public.geocode_cities() from public, anon, authenticated;

-- Opted-in members of your own crew, placed at their city's center.
create or replace function public.member_map(p_crew uuid)
returns table (person_id uuid, city text, lat double precision, lng double precision)
language sql stable security definer set search_path = '' as $$
  select p.id, initcap(trim(p.city)), g.lat, g.lng
  from public.people p join public.city_geo g on g.city_key = lower(trim(p.city))
  where p.crew_id = p_crew and p.show_on_map and p.status in ('active','rookie')
    and g.lat is not null and public.in_crew(p_crew);
$$;
revoke all on function public.member_map(uuid) from public, anon;
grant execute on function public.member_map(uuid) to authenticated;

select cron.schedule('geocode-cities', '*/10 * * * *', 'select public.geocode_cities()');
