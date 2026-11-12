-- Fix: Dropbox connect failed with "http_request.content is NULL". The account lookup now sends a JSON null body
-- (what Dropbox expects), so the connection is no longer rolled back after Allow.
-- Connecting no longer switches on photo calls by itself, so a test run can happen before real events get one.

create or replace function public.media_oauth_finish(p_state text, p_code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare m public.crew_media; r record; j jsonb; t text;
begin
  select * into m from public.crew_media where oauth_state = p_state;
  if m.crew_id is null then return 'unknown'; end if;
  select status, content into r from extensions.http_post('https://api.dropboxapi.com/oauth2/token',
    'grant_type=authorization_code&code=' || p_code || '&client_id=' || m.app_key || '&client_secret=' || m.app_secret
    || '&redirect_uri=https%3A%2F%2Ffwptdvoifkfljblyziva.supabase.co%2Ffunctions%2Fv1%2Fbusters-dropbox', 'application/x-www-form-urlencoded');
  if r.status <> 200 then return 'token ' || r.status || ' ' || left(r.content, 200); end if;
  j := r.content::jsonb;
  update public.crew_media set refresh_token = j->>'refresh_token', access_token = j->>'access_token',
    access_expires = now() + make_interval(secs => coalesce((j->>'expires_in')::int, 14400)),
    oauth_state = null, connected_by = m.oauth_by, connected_at = now(), updated_at = now() where crew_id = m.crew_id;
  select status, content into r from extensions.http(('POST', 'https://api.dropboxapi.com/2/users/get_current_account',
    array[extensions.http_header('Authorization', 'Bearer ' || (j->>'access_token'))], 'application/json', 'null')::extensions.http_request);
  if r.status = 200 then
    update public.crew_media set account_name = r.content::jsonb->'name'->>'display_name', account_email = r.content::jsonb->>'email' where crew_id = m.crew_id;
  end if;
  perform public.dbx_call(m.crew_id, 'files/create_folder_v2', jsonb_build_object('path', m.root_folder, 'autorename', false));
  return 'ok';
end $$;
revoke all on function public.media_oauth_finish(text, text) from public, anon, authenticated;
