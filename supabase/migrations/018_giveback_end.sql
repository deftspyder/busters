-- Give Back drive end date per crew (LAGB: about June 1, 2027), editable from the Team tab goal card.
alter table public.crews add column if not exists give_back_ends date;
update public.crews set give_back_ends = '2027-06-01' where slug = 'lagb' and give_back_ends is null;
-- set_giveback_goal gains p_ends date; giveback_for_crew returns 'ends'. Full definitions applied live as 018_giveback_end.
