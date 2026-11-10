create extension if not exists pg_net;
select cron.schedule('busters-alerts', '*/15 * * * *',
  $$select net.http_post(url := 'https://fwptdvoifkfljblyziva.supabase.co/functions/v1/busters-alerts', body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb)$$);
