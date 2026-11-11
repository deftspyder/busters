-- Give Back update card: whenever Sony's official totals change (a new giveback_snapshots row), the bot posts a card
-- in the crew's channel with what changed for the crew (amount, rank) and the campaign, plus the top 10.
-- Only the newest card stays: the previous one is deleted (a bump). Waits out quiet hours, then covers everything
-- since the last card. Skipped when a milestone card already went out in the last 20 minutes (that card says it).

alter table public.crew_discord
  add column if not exists post_giveback_updates boolean not null default true,
  add column if not exists giveback_snap_shown bigint;   -- snapshot the last update card covered

-- Start from today's numbers so the first card is a real update, not a replay.
update public.crew_discord set giveback_snap_shown = (select max(id) from public.giveback_snapshots)
where giveback_snap_shown is null;

create or replace function public.dc_giveback_update() returns int
language plpgsql security definer set search_path = '' as $$
declare d record; s record; p record; now_amt numeric; now_rnk int; old_amt numeric; old_rnk int;
  e jsonb; head text; lines text; st int; old record; n int := 0; lid bigint;
begin
  select * into s from public.giveback_snapshots order by id desc limit 1;
  if s.id is null then return 0; end if;
  for d in select cd.*, c.give_back_name, coalesce(c.short_name, c.name) as crew_name
           from public.crew_discord cd join public.crews c on c.id = cd.crew_id
           where cd.bot_token is not null and cd.channel_id is not null and cd.post_giveback_updates
             and c.give_back_name is not null loop
    continue when d.giveback_snap_shown is not null and d.giveback_snap_shown >= s.id;
    continue when public.dc_quiet(d.quiet_from, d.quiet_to);
    if exists (select 1 from public.discord_log where crew_id = d.crew_id and kind = 'milestone' and status between 200 and 299
               and at > now() - interval '20 minutes') then
      update public.crew_discord set giveback_snap_shown = s.id where crew_id = d.crew_id; continue;
    end if;
    select * into p from public.giveback_snapshots where id = d.giveback_snap_shown;

    select x.amount, x.rnk into now_amt, now_rnk from (
      select (g->>'amount')::numeric as amount, rank() over (order by (g->>'amount')::numeric desc) as rnk, g->>'name' as name
      from jsonb_array_elements(s.groups) g) x where lower(x.name) = lower(d.give_back_name);
    old_amt := null; old_rnk := null;
    if p.id is not null then
      select x.amount, x.rnk into old_amt, old_rnk from (
        select (g->>'amount')::numeric as amount, rank() over (order by (g->>'amount')::numeric desc) as rnk, g->>'name' as name
        from jsonb_array_elements(p.groups) g) x where lower(x.name) = lower(d.give_back_name);
    end if;

    head := case
      when now_amt is not null and now_amt > coalesce(old_amt, 0)
        then d.crew_name || ' is up ' || public.dc_money(now_amt - coalesce(old_amt, 0)) || '!'
      else 'Sony updated the Give Back totals' end;
    lines := case
      when now_amt is null then 'No donations credited to ' || d.crew_name || ' yet.'
      when now_amt > coalesce(old_amt, 0) then 'New donations credited to ' || d.crew_name || ' since the last update. Thank you!'
      else 'No change for ' || d.crew_name || ' this round.' end
      || case when now_rnk is not null and old_rnk is not null and now_rnk < old_rnk then E'\n⬆️ Up from #' || old_rnk || ' to #' || now_rnk || '.'
              when now_rnk is not null and old_rnk is not null and now_rnk > old_rnk then E'\n⬇️ Down from #' || old_rnk || ' to #' || now_rnk || '.'
              else '' end
      || case when p.id is not null and s.total > p.total then E'\nThe campaign grew by ' || public.dc_money(s.total - p.total) || '.' else '' end;

    e := public.dc_giveback_embed(d.crew_id);
    continue when e is null;
    e := e || jsonb_build_object(
      'author', jsonb_build_object('name', '📊 Give Back totals updated', 'icon_url', 'https://busters.app/icons/icon-192.png?v=4'),
      'title', head,
      'description', lines || E'\n\n' || coalesce(e->>'description', ''));

    st := public.discord_send_payload(d.crew_id, jsonb_build_object('embeds', jsonb_build_array(e), 'components', public.dc_donate_button()), head);
    insert into public.discord_log (crew_id, kind, status, preview) values (d.crew_id, 'giveback_update', st, head) returning id into lid;
    if st between 200 and 299 then
      -- bump: remove the previous update card so only the newest stays in the channel
      for old in select id, channel_id, message_id from public.discord_log
                 where crew_id = d.crew_id and kind = 'giveback_update' and message_id is not null and deleted_at is null
                   and id <> lid loop
        if public.dc_http(d.crew_id, 'DELETE', '/channels/' || old.channel_id || '/messages/' || old.message_id, null) in (200, 204, 404) then
          update public.discord_log set deleted_at = now() where id = old.id;
        end if;
      end loop;
      update public.crew_discord set giveback_snap_shown = s.id where crew_id = d.crew_id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.dc_giveback_update() from public, anon, authenticated;

-- Run it from the 15-minute Discord runner, right after milestones.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.discord_run()'::regprocedure);
  if position('dc_giveback_update' in d) = 0 then
    d := replace(d, '  n := n + public.dc_giveback_milestones();',
                    E'  n := n + public.dc_giveback_milestones();\n  n := n + public.dc_giveback_update();');
    execute d;
  end if;
end $$;
