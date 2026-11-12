-- The action log is a Busters (app) tool, not a crew role: only app admins can read it.
drop policy if exists log_read on public.action_log;
create policy log_read on public.action_log for select using (public.is_app_admin());
-- The crew-level "view action log" ability is retired; take it off anyone who has it.
update public.people set abilities = array_remove(abilities, 'view_log') where 'view_log' = any(abilities);
