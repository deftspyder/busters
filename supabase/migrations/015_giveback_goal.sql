alter table public.crews add column if not exists give_back_last_total numeric;

-- Crew admins set this drive's goal; a blank goal falls back to last drive's total.
create or replace function public.set_giveback_goal(p_crew uuid, p_goal numeric, p_last_total numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can(p_crew, 'crew_admin') then raise exception 'not allowed'; end if;
  update public.crews set give_back_last_total = p_last_total,
         give_back_goal = coalesce(p_goal, p_last_total)
   where id = p_crew;
  perform public.log_action(p_crew, 'giveback_goal', 'crew', p_crew,
    'Give Back goal set to $' || coalesce(to_char(coalesce(p_goal, p_last_total), 'FM999,999,990'), 'none')
    || coalesce(' (last drive $' || to_char(p_last_total, 'FM999,999,990') || ')', ''));
end $$;
revoke all on function public.set_giveback_goal(uuid, numeric, numeric) from public, anon;
grant execute on function public.set_giveback_goal(uuid, numeric, numeric) to authenticated;

create or replace function public.giveback_for_crew(p_crew uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select * from giveback_snapshots order by taken_at desc limit 1),
  rows as (
    select e->>'name' as name, (e->>'amount')::numeric as amount,
           rank() over (order by (e->>'amount')::numeric desc) as rnk
    from s, jsonb_array_elements(s.groups) e
  ),
  me as (select r.* from rows r, crews c where c.id = p_crew and lower(r.name) = lower(c.give_back_name))
  select jsonb_build_object(
    'taken_at', (select taken_at from s),
    'total', (select total from s),
    'groups', (select count(*) from rows),
    'amount', (select amount from me),
    'rank', (select rnk from me),
    'goal', (select coalesce(give_back_goal, give_back_last_total) from crews where id = p_crew),
    'last_total', (select give_back_last_total from crews where id = p_crew)
  );
$$;
