-- Run after prepare-default-shared-trades.sql, before activating the route.
-- This is read-only and returns exactly one row.
select league.shared_workspace_enabled as shared_route_active,
  to_regprocedure('public.claim_league_cast_member_without_default(uuid,uuid,uuid)')
    is not null as claim_bridge_installed,
  to_regprocedure('public.respond_to_league_trade_without_default(uuid,text,text,uuid)')
    is not null as trade_bridge_installed,
  (select count(*) from public.trade_offers
    where league_id = league.id) as legacy_open_offers,
  (select count(*) from public.league_trade_offers
    where league_id = league.id) as shared_open_offers,
  (select count(*) from public.weekly_roster_snapshots
    where league_id = league.id) as legacy_snapshots,
  (select count(*) from public.league_weekly_roster_snapshots
    where league_id = league.id) as shared_snapshots,
  (select count(*) from public.trade_history
    where league_id = league.id) as legacy_trade_events,
  (select count(*) from public.league_trade_events
    where league_id = league.id) as shared_trade_events
from public.leagues league
where league.id = public.default_fantasy_league_id();
