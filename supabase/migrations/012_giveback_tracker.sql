-- Ghostbusters Give Back tracker: hourly snapshot of Sony's public feed, cleaned, plus a per-crew summary for the app.
create table if not exists public.giveback_snapshots (
  id bigserial primary key,
  taken_at timestamptz not null default now(),
  total numeric not null,
  groups jsonb not null
);
alter table public.giveback_snapshots enable row level security;

create or replace function public.giveback_sync() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r record; j jsonb; g jsonb; tot numeric; last jsonb;
begin
  select status, content into r from extensions.http_get('https://secure.sonypictures.com/ghostbusters/donation/getDataAjax.php');
  if r.status <> 200 then return 'http ' || r.status; end if;
  begin j := r.content::jsonb; exception when others then return 'bad json'; end;
  if coalesce((j->>'success')::boolean, false) is not true or jsonb_typeof(j->'cash') <> 'array' then return 'no data'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', n, 'amount', a) order by a desc, n), '[]'::jsonb), coalesce(sum(a), 0)
    into g, tot
  from (
    select left(btrim(regexp_replace(regexp_replace(x->>'group_name', '<[^>]*>', '', 'g'), '[<>"]', '', 'g')), 80) as n,
           round((x->>'total_amount')::numeric, 2) as a
    from jsonb_array_elements(j->'cash') x
    where (x->>'total_amount') ~ '^[0-9.]+$' and (x->>'total_amount')::numeric > 0
  ) s where n <> '';
  select groups into last from giveback_snapshots order by taken_at desc limit 1;
  if last is not null and last = g then return 'unchanged'; end if;
  insert into giveback_snapshots (total, groups) values (tot, g);
  return 'saved ' || jsonb_array_length(g) || ' groups, $' || tot;
end $$;
revoke all on function public.giveback_sync() from public, anon, authenticated;

create or replace function public.giveback_for_crew(p_crew uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select * from giveback_snapshots order by taken_at desc limit 1),
  rows as (
    select e->>'name' as name, (e->>'amount')::numeric as amount,
           rank() over (order by (e->>'amount')::numeric desc) as rnk
    from s, jsonb_array_elements(s.groups) e
  ),
  me as (select r.* from rows r, crews c where c.id = p_crew and lower(r.name) = lower(c.give_back_name))
  select case when (select count(*) from s) = 0 then null else jsonb_build_object(
    'taken_at', (select taken_at from s),
    'total', (select total from s),
    'groups', (select count(*) from rows),
    'amount', (select amount from me),
    'rank', (select rnk from me),
    'goal', (select give_back_goal from crews where id = p_crew)
  ) end;
$$;
revoke all on function public.giveback_for_crew(uuid) from public, anon;
grant execute on function public.giveback_for_crew(uuid) to authenticated;

create extension if not exists pg_cron;
select cron.schedule('giveback-sync', '7 * * * *', 'select public.giveback_sync()');
select public.giveback_sync();
