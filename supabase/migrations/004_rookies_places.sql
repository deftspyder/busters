-- Rookie event counts from the old sheet, and venue pins for saved places (venues only, never people).
alter table public.people add column rookie_events_before int;
alter table public.places add column lat double precision, add column lng double precision;
-- event_missing(): an address or a pin both count as a place to navigate to.
