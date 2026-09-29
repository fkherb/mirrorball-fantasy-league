-- Read-only owner check for Kalshi refreshes and durable graph snapshots.
-- Run in the Supabase SQL editor. A current refresh may have no new snapshot
-- when quotes did not change or only eliminated partnerships had markets.
with history as (
  select count(*) as total_snapshots,
    count(*) filter (where observed_at >= now() - interval '24 hours') as snapshots_24h,
    max(observed_at) as last_snapshot_at,
    count(distinct cast_member_id) as cast_with_history
  from public.cast_market_prediction_history
), current_quotes as (
  select count(*) as current_markets, max(fetched_at) as last_quote_at
  from public.cast_market_predictions
)
select state.refreshed_at as last_refresh_at,
  state.snapshot_bucket as last_snapshot_bucket,
  history.total_snapshots, history.snapshots_24h,
  history.last_snapshot_at, history.cast_with_history,
  current_quotes.current_markets, current_quotes.last_quote_at,
  now() - state.refreshed_at as refresh_age
from public.market_prediction_sync_state state
cross join history cross join current_quotes
where state.id = 1;
