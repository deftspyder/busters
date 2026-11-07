-- Birthdays are month and day only ("MM-DD"); the year is never stored.
-- App admins can be named by email before they first sign in. Creates the LAGB crew.
-- (Applied to the live project; see Supabase migration history for the exact text.)
alter table public.people_private alter column birthday type text using to_char(birthday, 'MM-DD');
alter table public.people_private add constraint birthday_md check (birthday is null or birthday ~ '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$');
create table public.app_admin_emails (email text primary key);
alter table public.app_admin_emails enable row level security;
alter function public.event_missing(public.events) security invoker;
insert into public.crews (slug, name, short_name, give_back_goal, give_back_name)
  values ('lagb', 'Los Angeles Ghostbusters', 'LAGB', 65000, 'Los Angeles Ghostbusters');
-- public.md(text), updated save_person / save_my_details and is_app_admin(): see live project.
