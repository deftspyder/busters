-- Which place the Discord card shows and Navigate opens: Meeting point first, then Event, then Staging,
-- then any other label. Never parking or food stops (dinner, lunch, etc.); those still show under Details.
create or replace function public.dc_primary_place(p_event uuid) returns table (name text, address text, label text)
language sql stable security definer set search_path = '' as $$
  select p.name, p.address, ep.label from public.event_places ep join public.places p on p.id = ep.place_id
  where ep.event_id = p_event
    and coalesce(lower(ep.label), 'event') !~ '(park|dinner|lunch|breakfast|food|eat|restaurant|snack|meal)'
  order by case when lower(trim(ep.label)) = 'meeting point' then 1
                when ep.label is null or lower(trim(ep.label)) = 'event' then 2
                when lower(trim(ep.label)) like 'staging%' then 3 else 4 end, ep.sort
  limit 1;
$$;

-- dc_embed and dc_buttons now pick their place with dc_primary_place.
do $$ declare d text; begin
  d := pg_get_functiondef('public.dc_embed(uuid,text,text)'::regprocedure);
  d := replace(d, $x$select p.name, p.address, ep.label into pl from public.event_places ep join public.places p on p.id = ep.place_id
    where ep.event_id = p_event order by (coalesce(ep.label, 'Event') = 'Event') desc, ep.sort limit 1;$x$,
    $x$select pp.name, pp.address, pp.label into pl from public.dc_primary_place(p_event) pp;$x$);
  execute d;
  d := pg_get_functiondef('public.dc_buttons(uuid)'::regprocedure);
  d := replace(d, $x$select coalesce(p.address, p.name) into addr from public.event_places ep join public.places p on p.id = ep.place_id
    where ep.event_id = p_event order by (coalesce(ep.label, 'Event') = 'Event') desc, ep.sort limit 1;$x$,
    $x$select coalesce(pp.address, pp.name) into addr from public.dc_primary_place(p_event) pp;$x$);
  execute d;
end $$;
