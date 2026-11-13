-- Saved places: the Events role can rename, fix the address or type of, retire and bring back a saved place
-- (Admin, then Events, Saved places). Retired places stop showing as suggestions in the editor; events already using
-- them keep them. Also cleans up names that had an event name baked in, and a typo from the sheet.

create or replace function public.save_place(p_place uuid, p jsonb) returns void
language plpgsql security definer set search_path to '' as $$
declare pl public.places; nm text;
begin
  select * into pl from public.places where id = p_place;
  if pl.id is null or not public.can(pl.crew_id, 'edit_events') then raise exception 'not allowed'; end if;
  nm := nullif(btrim(coalesce(p->>'name', '')), '');
  if p ? 'name' and nm is null then raise exception 'A place needs a name'; end if;
  update public.places set
    name = coalesce(left(nm, 120), name),
    address = case when p ? 'address' then nullif(btrim(p->>'address'), '') else address end,
    kind = case when p ? 'kind' then nullif(btrim(p->>'kind'), '') else kind end,
    lat = case when p ? 'address' and nullif(btrim(p->>'address'), '') is distinct from address then null else lat end,
    lng = case when p ? 'address' and nullif(btrim(p->>'address'), '') is distinct from address then null else lng end,
    retired_at = case when p ? 'retired' then case when (p->>'retired')::boolean then coalesce(retired_at, now()) end else retired_at end
  where id = pl.id;
  perform public.log_action(pl.crew_id, case when p ? 'retired' then case when (p->>'retired')::boolean then 'place_retired' else 'place_restored' end else 'place_edited' end,
    'place', pl.id, case when p ? 'retired' then case when (p->>'retired')::boolean then 'Retired place ' else 'Brought back place ' end else 'Edited place ' end || coalesce(nm, pl.name));
end $$;
grant execute on function public.save_place(uuid, jsonb) to authenticated;

-- LAGB clean-up (Nov 12): event names out of place names, and the "BIvd" typo.
update public.places set name = '6922 Hollywood Blvd garage' where name = 'Hollywood Christmas Parade parking: 6922 Hollywood Blvd garage';
update public.places set name = 'Hollywood & Highland' where name = 'Hollywood Christmas Parade parking: Hollywood & Highland';
update public.places set name = 'Buffalo Wild Wings Hollywood' where name = 'Hollywood Christmas Parade: Buffalo Wild Wings';
update public.places set name = '403 W. Adams Blvd.', address = '403 W. Adams Blvd., Los Angeles, CA 90007', lat = null, lng = null where name = '403 W. Adams BIvd.';
