-- Run after storing market_prediction_sync_url and market_prediction_sync_secret
-- in Supabase Vault. Both values are read at execution time, not saved in cron.job.
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'market_prediction_sync_url')
    or not exists (select 1 from vault.decrypted_secrets where name = 'market_prediction_sync_secret') then
    raise exception 'Store market_prediction_sync_url and market_prediction_sync_secret in Supabase Vault first.';
  end if;
end;
$$;

select cron.schedule(
  'mirrorball-market-predictions',
  '*/5 * * * *',
  $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets
              where name = 'market_prediction_sync_url'),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                      where name = 'market_prediction_sync_secret')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 120000
    );
  $job$
);
