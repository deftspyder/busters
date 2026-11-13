-- Tighten who can call what.
-- 1. Discord card helpers are only used inside the database: nobody signed out (or signed in) needs to call them.
revoke all on function public.dc_card_embed(uuid, text, text) from public, anon, authenticated;
revoke all on function public.dc_buttons(uuid) from public, anon, authenticated;
revoke all on function public.dc_primary_place(uuid) from public, anon, authenticated;
revoke all on function public.discord_log_fill() from public, anon, authenticated;

-- 2. These already refuse anyone who isn't signed in; stop offering them to signed-out callers at all.
revoke all on function public.add_event_file(uuid, text, text, text, integer) from public, anon;
revoke all on function public.remove_event_file(uuid) from public, anon;
revoke all on function public.set_event_flyer(uuid) from public, anon;
revoke all on function public.refresh_event_card(uuid) from public, anon;
revoke all on function public.can_edit_event(uuid) from public, anon;
revoke all on function public.save_place(uuid, jsonb) from public, anon;
revoke all on function public.set_status(uuid, text) from public, anon;
revoke all on function public.set_honorary(uuid, boolean) from public, anon;
revoke all on function public.set_registry_check(uuid, text) from public, anon;
revoke all on function public.registry_checks_for(uuid) from public, anon;
revoke all on function public.bridge_status(uuid) from public, anon;
grant execute on function public.add_event_file(uuid, text, text, text, integer), public.remove_event_file(uuid), public.set_event_flyer(uuid),
  public.refresh_event_card(uuid), public.can_edit_event(uuid), public.save_place(uuid, jsonb), public.set_status(uuid, text),
  public.set_honorary(uuid, boolean), public.set_registry_check(uuid, text), public.registry_checks_for(uuid), public.bridge_status(uuid) to authenticated;

-- 3. The alerts sender only runs for the database's own timer: the timer now sends a key the sender checks.
insert into public.app_keys (name, value) values ('alerts_secret', encode(extensions.gen_random_bytes(24), 'hex')) on conflict do nothing;
select cron.schedule('busters-alerts', '*/15 * * * *',
  $$select net.http_post(url := 'https://fwptdvoifkfljblyziva.supabase.co/functions/v1/busters-alerts',
      body := jsonb_build_object('secret', (select value from public.app_keys where name = 'alerts_secret')),
      headers := '{"Content-Type":"application/json"}'::jsonb)$$);
