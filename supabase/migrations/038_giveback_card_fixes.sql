-- /giveback card fixes: escape the rank numbers so Discord doesn't turn them into an indented list, and show
-- when the numbers were last checked (the sync runs hourly at :07 and only saves when something changed).
do $$ declare d text; begin
  d := pg_get_functiondef('public.dc_giveback_embed(uuid)'::regprocedure);
  d := replace(d, $x$then '**' || rnk || '. ' || name$x$, $x$then '**' || rnk || '\. ' || name$x$);
  d := replace(d, $x$else rnk || '. ' || name$x$, $x$else rnk || '\. ' || name$x$);
  d := replace(d, $x$E'\n…\n**' || me.rnk || '. ' || me.name$x$, $x$E'\n…\n**' || me.rnk || '\. ' || me.name$x$);
  d := replace(d, $x$'timestamp', to_char(s.taken_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')$x$,
                  $x$'timestamp', to_char((date_trunc('hour', now()) + interval '7 minutes' - case when now() < date_trunc('hour', now()) + interval '7 minutes' then interval '1 hour' else interval '0' end) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')$x$);
  d := replace(d, $x$· Official numbers lag while Sony approves donations'$x$, $x$· Checked hourly; official numbers lag while Sony approves donations'$x$);
  execute d;
end $$;
