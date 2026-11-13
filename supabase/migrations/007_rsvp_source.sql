-- Where a sign-up came from: the app, or copied from the yearly sheet. Used to measure adoption.
alter table public.rsvps add column source text not null default 'app';
update public.rsvps set source = 'sheet'
  where crew_id = (select id from public.crews where slug = 'lagb');
