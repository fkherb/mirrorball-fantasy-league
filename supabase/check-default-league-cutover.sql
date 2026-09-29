-- Read-only checks for the original league's shared-workspace cutover.
-- Run in the Supabase SQL editor after shadow-default-league-snapshots.sql.
-- Returns exactly one result row. All mismatch counts must be zero before
-- changing the website route.
with legacy as (
  select * from public.weekly_roster_snapshots
  where league_id = public.default_fantasy_league_id()
), shared as (
  select * from public.league_weekly_roster_snapshots
  where league_id = public.default_fantasy_league_id()
)
select (select count(*) from legacy) as legacy_snapshots,
  (select count(*) from shared) as shared_snapshots,
  (select count(*) from legacy l full join shared s
    on s.league_id = l.league_id and s.week_id = l.week_id
      and s.cast_member_id = l.cast_member_id
    where l.cast_member_id is null or s.cast_member_id is null
      or (l.fantasy_team_id, l.cast_member_name, l.cast_role,
          l.appearance_points, l.manager_name, l.team_name, l.created_at)
        is distinct from
         (s.fantasy_team_id, s.cast_member_name, s.cast_role,
          s.appearance_points, s.manager_name, s.team_name, s.created_at))
    as snapshot_mismatches,
  (select count(*) from public.cast_members c
    full join (select * from public.league_roster_assignments
      where league_id = public.default_fantasy_league_id()) a
      on a.cast_member_id = c.id
    where c.id is null or a.cast_member_id is null
      or c.fantasy_team_id is distinct from a.fantasy_team_id)
    as assignment_mismatches,
  (select count(*) from public.roles r
    full join (select * from public.league_role_rates
      where league_id = public.default_fantasy_league_id()) rate
      on rate.role_id = r.id
    where r.id is null or rate.role_id is null
      or r.appearance_points is distinct from rate.appearance_points)
    as rate_mismatches,
  (select count(*) from public.trade_offers
    where league_id = public.default_fantasy_league_id()) as legacy_open_offers,
  (select count(*) from public.league_trade_offers
    where league_id = public.default_fantasy_league_id()) as shared_open_offers,
  (select count(*) from public.trade_history
    where league_id = public.default_fantasy_league_id()) as legacy_trade_events,
  (select count(*) from public.league_trade_events
    where league_id = public.default_fantasy_league_id()) as shared_trade_events,
  (select count(*) from public.trade_history
    where league_id = public.default_fantasy_league_id()
      and notification_team_id is not null and dismissed_at is null)
    as legacy_unread_results,
  (select count(*) from public.trade_history
    where league_id = public.default_fantasy_league_id()
      and (initiator_team_id is null or counterparty_team_id is null))
    as unmappable_legacy_events,
  (select count(*) from public.trade_history h
    full join public.league_trade_events e on e.id = h.id
      and e.league_id = public.default_fantasy_league_id()
    where (h.league_id = public.default_fantasy_league_id() or h.id is null)
      and (h.id is null or e.id is null
        or (h.trade_id, h.event_type, h.initiator_team_id,
            h.counterparty_team_id, h.initiator_cast_member_name,
            h.counterparty_cast_member_name, h.notification_team_id,
            h.dismissed_at, h.event_at)
          is distinct from
           (e.trade_id, e.event_type, e.initiator_team_id,
            e.counterparty_team_id, e.initiator_cast_member_name,
            e.counterparty_cast_member_name, e.notification_team_id,
            e.dismissed_at, e.event_at))) as trade_event_mismatches;
