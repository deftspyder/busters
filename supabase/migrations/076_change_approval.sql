-- Member edits wait for Personnel. When a member changes their own callsign, phone, Discord name, Instagram,
-- birthday or city in My details, the change is held as pending and the old info stays live until someone with
-- Personnel (manage_recruits) approves it. Sharing choices (phone, email, map, join every thread) are the member's
-- own privacy settings and still apply right away. Personnel and crew admins' own edits apply right away.
-- One pending row per person: a new save updates what was waiting. Saving back to the current values clears it.

create table if not exists public.people_changes (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references public.crews(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  changes jsonb not null,            -- { field: { "old": ..., "new": ... } }
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.people(id),
  decision text check (decision in ('approved', 'declined', 'withdrawn'))
);
create unique index if not exists people_changes_one_pending on public.people_changes (person_id) where decided_at is null;
alter table public.people_changes enable row level security;  -- no policies: only the functions below touch it
revoke all on public.people_changes from anon, authenticated;

-- Write a set of detail fields onto a person (internal only).
create or replace function public.people_apply(pid uuid, p jsonb)
returns void language plpgsql security definer set search_path to '' as $$
begin
  update public.people set
    callsign = case when p ? 'callsign' then nullif(trim(p->>'callsign'),'') else callsign end,
    city = case when p ? 'city' then nullif(trim(p->>'city'),'') else city end,
    show_on_map = coalesce((p->>'show_on_map')::boolean, show_on_map),
    updated_at = now()
  where id = pid;
  update public.people_private set
    phone = case when p ? 'phone' then nullif(trim(p->>'phone'),'') else phone end,
    discord = case when p ? 'discord' then nullif(trim(p->>'discord'),'') else discord end,
    instagram = case when p ? 'instagram' then nullif(trim(p->>'instagram'),'') else instagram end,
    birthday = case when p ? 'birthday' then public.md(p->>'birthday') else birthday end,
    share_phone = coalesce((p->>'share_phone')::boolean, share_phone),
    share_email = coalesce((p->>'share_email')::boolean, share_email),
    join_all_threads = coalesce((p->>'join_all_threads')::boolean, join_all_threads)
  where person_id = pid;
end; $$;
revoke all on function public.people_apply(uuid, jsonb) from public, anon, authenticated;

create or replace function public.save_my_details(p_crew uuid, p jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare pid uuid; cur jsonb; diff jsonb := '{}'; f text; nv text; ov text; prev jsonb;
  held text[] := array['callsign','phone','discord','instagram','birthday','city'];
begin
  select id into pid from public.people where crew_id = p_crew and user_id = auth.uid();
  if pid is null then raise exception 'not in this crew'; end if;
  if public.can(p_crew, 'manage_recruits') then
    perform public.people_apply(pid, p);
    return;
  end if;
  -- Privacy choices apply now.
  perform public.people_apply(pid, p - held);
  select jsonb_build_object('callsign', pe.callsign, 'city', pe.city, 'phone', pp.phone, 'discord', pp.discord,
      'instagram', pp.instagram, 'birthday', pp.birthday)
    into cur from public.people pe left join public.people_private pp on pp.person_id = pe.id where pe.id = pid;
  foreach f in array held loop
    if p ? f then
      nv := case when f = 'birthday' then public.md(p->>f) else nullif(trim(p->>f), '') end;
      ov := cur->>f;
      if nv is distinct from ov then diff := diff || jsonb_build_object(f, jsonb_build_object('old', ov, 'new', nv)); end if;
    end if;
  end loop;
  select changes into prev from public.people_changes where person_id = pid and decided_at is null;
  -- Fields this save didn't send stay waiting; fields it sent are replaced by what it sent.
  if prev is not null then
    select coalesce(jsonb_object_agg(k, v), '{}') into prev from jsonb_each(prev) as e(k, v) where not (p ? k);
    diff := prev || diff;
  end if;
  if diff = '{}' then
    -- Saved back to what's live: nothing left to approve.
    update public.people_changes set decided_at = now(), decision = 'withdrawn' where person_id = pid and decided_at is null;
  else
    update public.people_changes set changes = diff, created_at = now() where person_id = pid and decided_at is null;
    if not found then insert into public.people_changes (crew_id, person_id, changes) values (p_crew, pid, diff); end if;
    perform public.log_action(p_crew, 'details_submitted', 'person', pid, 'sent detail changes for Personnel to approve', diff);
  end if;
end; $$;
revoke all on function public.save_my_details(uuid, jsonb) from public, anon;
grant execute on function public.save_my_details(uuid, jsonb) to authenticated;

-- What I've sent that is still waiting (for My details).
create or replace function public.my_pending_change(p_crew uuid)
returns json language sql stable security definer set search_path to '' as $$
  select json_build_object('changes', c.changes, 'created_at', c.created_at)
  from public.people_changes c join public.people pe on pe.id = c.person_id
  where c.crew_id = p_crew and pe.user_id = auth.uid() and c.decided_at is null;
$$;
revoke all on function public.my_pending_change(uuid) from public, anon;
grant execute on function public.my_pending_change(uuid) to authenticated;

-- Everything waiting, for Personnel. Empty for anyone else.
create or replace function public.pending_changes(p_crew uuid)
returns json language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.can(p_crew, 'manage_recruits') then return '[]'::json; end if;
  return (select coalesce(json_agg(json_build_object('id', c.id, 'person_id', c.person_id, 'full_name', pe.full_name,
      'changes', c.changes, 'created_at', c.created_at) order by c.created_at), '[]')
    from public.people_changes c join public.people pe on pe.id = c.person_id
    where c.crew_id = p_crew and c.decided_at is null);
end; $$;
revoke all on function public.pending_changes(uuid) from public, anon;
grant execute on function public.pending_changes(uuid) to authenticated;

-- Approve (write the new values) or decline (keep the old ones).
create or replace function public.decide_change(p_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path to '' as $$
declare c record; vals jsonb;
begin
  select * into c from public.people_changes where id = p_id and decided_at is null;
  if c.id is null then raise exception 'already decided'; end if;
  if not public.can(c.crew_id, 'manage_recruits') then raise exception 'not allowed'; end if;
  if p_approve then
    select coalesce(jsonb_object_agg(k, coalesce(v->>'new', '')), '{}') into vals from jsonb_each(c.changes) as e(k, v);
    perform public.people_apply(c.person_id, vals);
  end if;
  update public.people_changes set decided_at = now(), decided_by = public.me(c.crew_id),
    decision = case when p_approve then 'approved' else 'declined' end where id = p_id;
  perform public.log_action(c.crew_id, case when p_approve then 'details_approved' else 'details_declined' end, 'person', c.person_id,
    case when p_approve then 'approved detail changes' else 'declined detail changes' end, c.changes);
end; $$;
revoke all on function public.decide_change(uuid, boolean) from public, anon;
grant execute on function public.decide_change(uuid, boolean) to authenticated;
