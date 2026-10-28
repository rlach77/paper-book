-- Schedules the daily odds pull. Run in the SQL editor AFTER the odds-pull Edge Function is deployed.
-- Replace PASTE-CRON-SECRET first with the same random string you saved as the function's CRON_SECRET secret.
-- 17:00 UTC = 10 AM Pacific during daylight time (9 AM in winter).

create extension if not exists pg_cron;
create extension if not exists pg_net;

select vault.create_secret('PASTE-CRON-SECRET', 'paperbook_cron_secret')
where not exists (select 1 from vault.secrets where name = 'paperbook_cron_secret');

select cron.schedule('paperbook-odds-pull', '0 17 * * *', $$
  select net.http_post(
    url := 'https://xbnmrdpbvtsvlmxmzfgi.supabase.co/functions/v1/odds-pull',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'paperbook_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000);
$$);

-- Run it once right now (result shows up in net._http_response a few seconds later):
--   select net.http_post(url := 'https://xbnmrdpbvtsvlmxmzfgi.supabase.co/functions/v1/odds-pull',
--     headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'paperbook_cron_secret')));
--   select status_code, content from net._http_response order by created desc limit 1;
-- See past runs:      select * from cron.job_run_details order by start_time desc limit 5;
-- Stop the schedule:  select cron.unschedule('paperbook-odds-pull');
