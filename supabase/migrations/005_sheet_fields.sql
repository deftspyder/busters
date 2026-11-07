-- Text carried over from the yearly Master Events List while it is still in use.
alter table public.events add column lagb_contact text, add column sheet_attendees text, add column sheet_reserve text;
-- events_full view rebuilt to include them.
