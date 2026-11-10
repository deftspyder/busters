-- Log answers given in the app (Going, Maybe, No and changes), one row per change.
create or replace function public.log_rsvp_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t text; nm text;
begin
  if coalesce(new.source, 'app') <> 'app' then return new; end if;
  if tg_op = 'UPDATE' and new.answer is not distinct from old.answer and new.note is not distinct from old.note then return new; end if;
  select title into t from public.events where id = new.event_id;
  select coalesce(callsign, full_name) into nm from public.people where id = new.person_id;
  insert into public.action_log (crew_id, actor_id, action, target_type, target_id, summary)
  values (new.crew_id, new.person_id, 'rsvp', 'event', new.event_id,
    coalesce(nm, 'Someone') || ' answered ' || case new.answer when 'going' then 'Going' when 'maybe' then 'Maybe' else 'No' end
    || ' for ' || coalesce(t, 'an event')
    || case when tg_op = 'UPDATE' and new.answer is distinct from old.answer then ' (was ' || initcap(old.answer) || ')'
            when tg_op = 'UPDATE' then ' (note changed)' else '' end);
  return new;
exception when others then return new;
end $$;
drop trigger if exists rsvps_log on public.rsvps;
create trigger rsvps_log after insert or update on public.rsvps for each row execute function public.log_rsvp_change();

-- Log sign-ins and sign-outs (a session starting or ending), for each crew the person belongs to.
create or replace function public.log_session_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare uid uuid := coalesce(new.user_id, old.user_id);
begin
  insert into public.action_log (crew_id, actor_id, action, target_type, target_id, summary)
  select p.crew_id, p.id, case when tg_op = 'INSERT' then 'signed_in' else 'signed_out' end, 'person', p.id,
         coalesce(p.callsign, p.full_name) || case when tg_op = 'INSERT' then ' signed in' else ' signed out' end
  from public.people p where p.user_id = uid;
  return coalesce(new, old);
exception when others then return coalesce(new, old);
end $$;
drop trigger if exists sessions_log on auth.sessions;
create trigger sessions_log after insert or delete on auth.sessions for each row execute function public.log_session_change();

revoke all on function public.log_rsvp_change(), public.log_session_change() from public, anon, authenticated;
