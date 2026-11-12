-- Photo file names saved from event threads use a 24-hour time ("2026-11-29 1925 ..."), not a 12-hour one with no AM/PM.
do $$
declare d text := pg_get_functiondef('public.media_harvest()'::regprocedure);
begin
  if position('HH24MI' in d) = 0 then
    execute replace(d, $x$'YYYY-MM-DD HHMI'$x$, $x$'YYYY-MM-DD HH24MI'$x$);
  end if;
end $$;
