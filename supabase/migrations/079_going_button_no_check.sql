-- Going button: drop the check mark. Discord shows the same buttons to everyone,
-- so a check on Going read like "you said Going" to people who hadn't answered.
-- Live cards pick this up on their next in-place update (dc_buttons is resent).
create or replace function public.dc_buttons(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare addr text; r jsonb;
begin
  select coalesce(pp.address, pp.name) into addr from public.dc_primary_place(p_event) pp;
  -- One row: Going / Maybe / Can't, then icon-only Navigate and Details (Discord allows 5 buttons per row).
  r := jsonb_build_array(
    jsonb_build_object('type', 2, 'style', 3, 'label', 'Going', 'custom_id', 'rsvp:' || p_event || ':going'),
    jsonb_build_object('type', 2, 'style', 2, 'label', 'Maybe', 'custom_id', 'rsvp:' || p_event || ':maybe'),
    jsonb_build_object('type', 2, 'style', 4, 'label', 'Can''t', 'custom_id', 'rsvp:' || p_event || ':no'));
  if addr is not null then
    r := r || jsonb_build_object('type', 2, 'style', 5, 'emoji', jsonb_build_object('name', '🧭'),
      'url', 'https://www.google.com/maps/search/?api=1&query=' || replace(replace(replace(replace(replace(replace(addr, '%', '%25'), '+', '%2B'), '&', '%26'), '?', '%3F'), '#', '%23'), ' ', '+'));
  end if;
  r := r || jsonb_build_object('type', 2, 'style', 2, 'emoji', jsonb_build_object('name', 'ℹ️'), 'custom_id', 'details:' || p_event);
  return jsonb_build_array(jsonb_build_object('type', 1, 'components', r));
end $$;

revoke all on function public.dc_buttons(uuid) from public, anon, authenticated;
