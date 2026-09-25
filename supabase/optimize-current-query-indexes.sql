-- Mirrorball Fantasy League: indexes for the current score, roster, snapshot,
-- and trade workflows. This changes no data, permissions, or scoring rules.
-- Run after fix-trade-counter-history-and-cancellation.sql.

begin;

-- Week views and completion validation repeatedly load dances in show order.
create index if not exists dances_week_kind_sort_idx
  on public.dances (week_id, kind, sort_order, id);

create index if not exists dances_partnership_idx
  on public.dances (partnership_id)
  where partnership_id is not null;

-- Cast-profile safeguards and appearance history look up appearances from the
-- cast-member side; the existing unique key begins with dance_id instead.
create index if not exists dance_appearances_cast_member_idx
  on public.dance_appearances (cast_member_id, dance_id);

-- Team pages and commissioner cards group the canonical cast by current team.
create index if not exists cast_members_fantasy_team_name_idx
  on public.cast_members (fantasy_team_id, name)
  where fantasy_team_id is not null;

-- The snapshot primary key is (week_id, cast_member_id). These cover the two
-- reverse lookup paths used by historical team scoring and deletion guards.
create index if not exists weekly_roster_snapshots_team_week_idx
  on public.weekly_roster_snapshots (fantasy_team_id, week_id)
  where fantasy_team_id is not null;

create index if not exists weekly_roster_snapshots_cast_week_idx
  on public.weekly_roster_snapshots (cast_member_id, week_id);

-- Active-trade conflict checks search both sides by cast member.
create index if not exists trade_offers_initiator_cast_idx
  on public.trade_offers (initiator_cast_member_id);

create index if not exists trade_offers_counterparty_cast_idx
  on public.trade_offers (counterparty_cast_member_id);

-- Keeps all events for one trade inexpensive to inspect or reconcile later.
create index if not exists trade_history_trade_event_idx
  on public.trade_history (trade_id, event_at desc);

commit;
