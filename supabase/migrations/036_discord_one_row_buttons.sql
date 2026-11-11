-- One row of buttons: Going / Maybe / Can't, then icon-only Navigate (🧭) and Details (ℹ️).
create or replace function public.dc_buttons(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare addr text; r jsonb;
begin
  select coalesce(pp.address, pp.name) into addr from public.dc_primary_place(p_event) pp;
  r := jsonb_build_array(
    jsonb_build_object('type', 2, 'style', 3, 'label', 'Going', 'emoji', jsonb_build_object('name', '✅'), 'custom_id', 'rsvp:' || p_event || ':going'),
    jsonb_build_object('type', 2, 'style', 2, 'label', 'Maybe', 'custom_id', 'rsvp:' || p_event || ':maybe'),
    jsonb_build_object('type', 2, 'style', 4, 'label', 'Can''t', 'custom_id', 'rsvp:' || p_event || ':no'));
  if addr is not null then
    r := r || jsonb_build_object('type', 2, 'style', 5, 'emoji', jsonb_build_object('name', '🧭'),
      'url', 'https://www.google.com/maps/search/?api=1&query=' || replace(replace(replace(replace(replace(replace(addr, '%', '%25'), '+', '%2B'), '&', '%26'), '?', '%3F'), '#', '%23'), ' ', '+'));
  end if;
  r := r || jsonb_build_object('type', 2, 'style', 2, 'emoji', jsonb_build_object('name', 'ℹ️'), 'custom_id', 'details:' || p_event);
  return jsonb_build_array(jsonb_build_object('type', 1, 'components', r));
end $$;
