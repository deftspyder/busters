-- Contact on a Buster's crew card: Discord is always there (members already see each other in the server), and each
-- Buster chooses whether their phone and email also show. Personnel always sees everything, as before.

alter table public.people_private add column if not exists share_email boolean not null default false;

create or replace function public.crew_contacts(p_crew uuid) returns table (person_id uuid, discord text, discord_user_id text, phone text, email text)
language sql stable security definer set search_path to '' as $$
  select pp.person_id, nullif(pp.discord, ''), pp.discord_user_id,
         case when pp.share_phone then pp.phone end, case when pp.share_email then pp.email end
  from public.people_private pp join public.people p on p.id = pp.person_id
  where pp.crew_id = p_crew and p.status in ('active', 'rookie') and public.in_crew(p_crew)
    and (pp.discord is not null or pp.discord_user_id is not null or (pp.share_phone and pp.phone is not null) or (pp.share_email and pp.email is not null));
$$;
revoke all on function public.crew_contacts(uuid) from public, anon;
grant execute on function public.crew_contacts(uuid) to authenticated;

-- My details can turn email sharing on or off.
do $$
declare d text := pg_get_functiondef('public.save_my_details(uuid,jsonb)'::regprocedure);
  f text := $x$share_phone = coalesce((p->>'share_phone')::boolean, share_phone)$x$;
begin
  if position('share_email' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'save_my_details: share_phone line not found once'; end if;
  execute replace(d, f, f || $x$, share_email = coalesce((p->>'share_email')::boolean, share_email)$x$);
end $$;

-- my_session returns share_email with the rest of my details.
do $$
declare d text := pg_get_functiondef('public.my_session(uuid)'::regprocedure);
  f text := $x$pp.email, pp.share_phone$x$;
begin
  if position('pp.share_email' in d) > 0 then return; end if;
  if (length(d) - length(replace(d, f, ''))) / length(f) <> 1 then raise exception 'my_session: share_phone column not found once'; end if;
  execute replace(d, f, f || ', pp.share_email');
end $$;
