-- One-time, guarded original-league cutover. Run only after the shared UI is
-- published and reviewed. A failed assertion rolls the entire switch back.
begin;

-- Stop a legacy offer or roster write from slipping between the parity check
-- and the flag update. These locks last only for this transaction.
lock table public.cast_members, public.league_roster_assignments,
  public.trade_offers, public.league_trade_offers in share row exclusive mode;

do $$
declare
  v_league_id uuid := public.default_fantasy_league_id();
  v_legacy_snapshots bigint;
  v_shared_snapshots bigint;
  v_legacy_events bigint;
  v_shared_events bigint;
begin
  perform 1 from public.leagues where id = v_league_id for update;
  if not found then raise exception 'Original league is missing.'; end if;
  if (select shared_workspace_enabled from public.leagues where id = v_league_id) then
    raise exception 'The shared workspace is already active.';
  end if;
  if to_regprocedure('public.claim_league_cast_member_without_default(uuid,uuid,uuid)') is null
     or to_regprocedure('public.respond_to_league_trade_without_default(uuid,text,text,uuid)') is null then
    raise exception 'The claim or trade bridge is missing.';
  end if;
  if exists (select 1 from public.trade_offers where league_id = v_league_id)
     or exists (select 1 from public.league_trade_offers where league_id = v_league_id) then
    raise exception 'Resolve open offers before switching trade paths.';
  end if;
  if exists (select 1 from public.trade_history
    where league_id = v_league_id and notification_team_id is not null
      and dismissed_at is null) then
    raise exception 'Legacy trade results still need to be read or migrated.';
  end if;

  select count(*) into v_legacy_snapshots from public.weekly_roster_snapshots
    where league_id = v_league_id;
  select count(*) into v_shared_snapshots from public.league_weekly_roster_snapshots
    where league_id = v_league_id;
  if v_legacy_snapshots = 0 or v_legacy_snapshots <> v_shared_snapshots
    or exists (
      select 1 from public.weekly_roster_snapshots legacy
      full join public.league_weekly_roster_snapshots shared
        on shared.league_id = legacy.league_id
          and shared.week_id = legacy.week_id
          and shared.cast_member_id = legacy.cast_member_id
      where (legacy.league_id = v_league_id or shared.league_id = v_league_id)
        and (legacy.cast_member_id is null or shared.cast_member_id is null
          or (legacy.fantasy_team_id, legacy.cast_member_name, legacy.cast_role,
              legacy.appearance_points, legacy.manager_name, legacy.team_name,
              legacy.created_at)
            is distinct from
             (shared.fantasy_team_id, shared.cast_member_name, shared.cast_role,
              shared.appearance_points, shared.manager_name, shared.team_name,
              shared.created_at))
    ) then
    raise exception 'Weekly snapshot parity failed.';
  end if;
  if exists (
    select 1 from public.cast_members cast_member
    full join public.league_roster_assignments assignment
      on assignment.league_id = v_league_id
        and assignment.cast_member_id = cast_member.id
    where cast_member.id is null or assignment.cast_member_id is null
      or cast_member.fantasy_team_id is distinct from assignment.fantasy_team_id
  ) then
    raise exception 'Current roster assignment parity failed.';
  end if;
  if exists (
    select 1 from public.roles role
    full join public.league_role_rates rate
      on rate.league_id = v_league_id and rate.role_id = role.id
    where role.id is null or rate.role_id is null
      or role.appearance_points is distinct from rate.appearance_points
  ) then
    raise exception 'Role rate parity failed.';
  end if;

  select count(*) into v_legacy_events from public.trade_history
    where league_id = v_league_id;
  select count(*) into v_shared_events from public.league_trade_events
    where league_id = v_league_id;
  if v_legacy_events <> v_shared_events or exists (
    select 1 from public.trade_history legacy
    full join public.league_trade_events shared
      on shared.id = legacy.id and shared.league_id = v_league_id
    where (legacy.league_id = v_league_id or shared.league_id = v_league_id)
      and (legacy.id is null or shared.id is null
        or (legacy.trade_id, legacy.event_type, legacy.initiator_team_id,
            legacy.counterparty_team_id, legacy.initiator_cast_member_name,
            legacy.counterparty_cast_member_name, legacy.notification_team_id,
            legacy.dismissed_at, legacy.event_at)
          is distinct from
           (shared.trade_id, shared.event_type, shared.initiator_team_id,
            shared.counterparty_team_id, shared.initiator_cast_member_name,
            shared.counterparty_cast_member_name, shared.notification_team_id,
            shared.dismissed_at, shared.event_at))
  ) then
    raise exception 'Trade history parity failed.';
  end if;

  update public.leagues set shared_workspace_enabled = true where id = v_league_id;
end;
$$;

select shared_workspace_enabled as shared_route_active
from public.leagues where id = public.default_fantasy_league_id();
commit;
