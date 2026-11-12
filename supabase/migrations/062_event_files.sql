-- Event attachments: flyers, maps, photos and PDFs the events team adds to an event. Stored in Busters' own storage
-- (bucket event-files, path <crew>/<event>/<random>-<name>). Members of the crew see them on the event page; the
-- Events role or the event's point of contact can add and remove them. One image can be the flyer, which shows as a
-- thumbnail on the event's Discord cards.

insert into storage.buckets (id, name, public, file_size_limit)
values ('event-files', 'event-files', true, 20971520)
on conflict (id) do update set public = true, file_size_limit = 20971520;

create table if not exists public.event_files (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  crew_id uuid not null references public.crews(id) on delete cascade,
  path text not null unique,
  name text not null,
  mime text not null default 'application/octet-stream',
  size integer,
  is_flyer boolean not null default false,
  created_by uuid references public.people(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists event_files_event on public.event_files(event_id);
alter table public.event_files enable row level security;
drop policy if exists event_files_read on public.event_files;
create policy event_files_read on public.event_files for select using (exists (select 1 from public.events e where e.id = event_files.event_id));

-- Who can change an event's attachments: the Events role (edit_events) or the event's point of contact.
create or replace function public.can_edit_event(p_event uuid) returns boolean
language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.events e where e.id = p_event
    and (public.can(e.crew_id, 'edit_events') or (e.poc_id is not null and e.poc_id = public.me(e.crew_id))));
$$;
grant execute on function public.can_edit_event(uuid) to authenticated;

-- Storage: uploads and deletes only under an event the person can edit. Reading is public (the bucket is public,
-- paths are unguessable), so Discord can show the flyer.
drop policy if exists event_files_upload on storage.objects;
create policy event_files_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'event-files' and public.can_edit_event(nullif((storage.foldername(name))[2], '')::uuid));
drop policy if exists event_files_remove on storage.objects;
create policy event_files_remove on storage.objects for delete to authenticated
  using (bucket_id = 'event-files' and public.can_edit_event(nullif((storage.foldername(name))[2], '')::uuid));

create or replace function public.add_event_file(p_event uuid, p_path text, p_name text, p_mime text, p_size integer) returns uuid
language plpgsql security definer set search_path to '' as $$
declare e public.events; new_id uuid; flyer boolean;
begin
  select * into e from public.events where events.id = p_event;
  if e.id is null or not public.can_edit_event(p_event) then raise exception 'not allowed'; end if;
  if split_part(p_path, '/', 1) <> e.crew_id::text or split_part(p_path, '/', 2) <> e.id::text then raise exception 'bad path'; end if;
  -- The first image added becomes the flyer.
  flyer := coalesce(p_mime, '') like 'image/%' and not exists (select 1 from public.event_files f where f.event_id = p_event and f.is_flyer);
  insert into public.event_files (event_id, crew_id, path, name, mime, size, is_flyer, created_by)
  values (p_event, e.crew_id, p_path, left(coalesce(nullif(btrim(p_name), ''), 'File'), 120), coalesce(nullif(p_mime, ''), 'application/octet-stream'), p_size, flyer, public.me(e.crew_id))
  returning event_files.id into new_id;
  perform public.log_action(e.crew_id, 'event_file_add', 'event', p_event, 'Added ' || left(p_name, 80) || ' to ' || e.title);
  return new_id;
end $$;
grant execute on function public.add_event_file(uuid, text, text, text, integer) to authenticated;

create or replace function public.remove_event_file(p_id uuid) returns text
language plpgsql security definer set search_path to '' as $$
declare f public.event_files; e public.events;
begin
  select * into f from public.event_files where id = p_id;
  if f.id is null or not public.can_edit_event(f.event_id) then raise exception 'not allowed'; end if;
  select * into e from public.events where id = f.event_id;
  delete from public.event_files where id = p_id;
  if f.is_flyer then  -- hand the flyer role to the next image, if any
    update public.event_files set is_flyer = true where id = (select id from public.event_files where event_id = f.event_id and mime like 'image/%' order by created_at limit 1);
  end if;
  perform public.log_action(e.crew_id, 'event_file_remove', 'event', f.event_id, 'Removed ' || left(f.name, 80) || ' from ' || e.title);
  return f.path;  -- the app deletes the stored file
end $$;
grant execute on function public.remove_event_file(uuid) to authenticated;

create or replace function public.set_event_flyer(p_id uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare f public.event_files;
begin
  select * into f from public.event_files where id = p_id;
  if f.id is null or not public.can_edit_event(f.event_id) then raise exception 'not allowed'; end if;
  if f.mime not like 'image/%' then raise exception 'Only an image can be the flyer'; end if;
  update public.event_files set is_flyer = (id = p_id) where event_id = f.event_id;
end $$;
grant execute on function public.set_event_flyer(uuid) to authenticated;

-- Discord cards show the flyer as a thumbnail (tap it in Discord to see it full size).
do $$
declare d text := pg_get_functiondef('public.dc_send_event(uuid,text,text)'::regprocedure);
  f text := $x$jsonb_build_array(public.dc_embed(p_event, p_kind, p_extra))$x$;
begin
  if position('event_files' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'dc_send_event: embed line not found once'; end if;
  execute replace(d, f, $x$jsonb_build_array(public.dc_embed(p_event, p_kind, p_extra) || coalesce((select jsonb_build_object('thumbnail', jsonb_build_object('url',
      'https://fwptdvoifkfljblyziva.supabase.co/storage/v1/object/public/event-files/' || f.path))
      from public.event_files f where f.event_id = p_event and f.is_flyer and f.mime like 'image/%' limit 1), '{}'::jsonb))$x$);
end $$;
