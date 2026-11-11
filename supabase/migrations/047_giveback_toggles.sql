-- Switches for the Give Back milestone and update cards in the Discord posting schedule (Admin, then Events).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.discord_schedule(uuid)'::regprocedure);
  if position('post_giveback_updates' in d) = 0 then
    d := replace(d, $x$'dm_interested', coalesce(d.dm_interested, true),$x$,
      $x$'dm_interested', coalesce(d.dm_interested, true), 'post_milestones', coalesce(d.post_milestones, true), 'post_giveback_updates', coalesce(d.post_giveback_updates, true),$x$);
    execute d;
  end if;
  d := pg_get_functiondef('public.set_discord_schedule(uuid,jsonb)'::regprocedure);
  if position('post_giveback_updates' in d) = 0 then
    d := replace(d, $x$    dm_interested = coalesce((p->>'dm_interested')::boolean, dm_interested),$x$,
      $x$    dm_interested = coalesce((p->>'dm_interested')::boolean, dm_interested),
    post_milestones = coalesce((p->>'post_milestones')::boolean, post_milestones),
    post_giveback_updates = coalesce((p->>'post_giveback_updates')::boolean, post_giveback_updates),$x$);
    execute d;
  end if;
end $$;
