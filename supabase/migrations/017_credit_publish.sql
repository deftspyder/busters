-- Fundraising credit stays hidden (draft) until a crew admin publishes the split.
alter table public.events add column if not exists credit_published boolean not null default false;
-- events_full gains credit_published; fundraising_credit counts only published events;
-- set_event_fundraising takes p_publish (admins only; any non-admin change returns it to draft).
-- Full definitions applied in the live project as migration 017_credit_publish.
