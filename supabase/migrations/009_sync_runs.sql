-- When background jobs last ran (the daily sheet check, later the calendar bridge). Not readable from the app.
create table public.sync_runs (
  id bigint generated always as identity primary key,
  crew_id uuid not null references public.crews(id) on delete cascade,
  kind text not null,
  ran_at timestamptz not null default now(),
  summary text
);
alter table public.sync_runs enable row level security;
create index on public.sync_runs (crew_id, kind, ran_at desc);
