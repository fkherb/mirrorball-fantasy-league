-- Run after airing-trade-and-draft-windows.sql and
-- draft-start-and-frozen-cast.sql. Drafts already in progress remain playable.
begin;

-- All leagues share one show-wide trade/free-agent lock. It begins at the
-- first scheduled airing start (Eastern), including two-night weeks, and ends
-- only when that week is marked complete. It never locks before airtime.
create or replace function public.league_trade_airing_locked(p_at timestamptz default clock_timestamp())
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.weeks w
    cross join lateral (values
      (w.air_date, w.air_start_time),
      (w.second_air_date, coalesce(w.second_air_start_time, w.air_start_time))
    ) as airing(day, starts)
    where not w.is_complete and airing.day is not null
      and p_at >= ((airing.day + airing.starts) at time zone 'America/New_York')
  );
$$;

-- The prior snapshot boundary was two hours early. Since roster changes now
-- remain legal until airtime, freeze the roster at airtime instead.
create or replace function public.capture_due_secondary_league_snapshots(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_week record; v_now timestamptz := clock_timestamp();
begin
  perform 1 from public.leagues where id = p_league_id for update;
  for v_week in select week.id from public.weeks week
    join public.leagues league on league.id = p_league_id
    where league.status = 'active' and week.number > league.scoring_starts_after_week
      and week.air_date is not null
      and v_now >= ((week.air_date + week.air_start_time) at time zone 'America/New_York')
  loop
    perform public.capture_secondary_league_week_snapshot(p_league_id, v_week.id);
  end loop;
end $$;

-- Direct roster writes in secondary leagues use this trigger; the shared
-- claim/trade RPCs also call the same central lock function.
create or replace function public.guard_secondary_league_roster_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid; v_status text;
begin
  v_league_id := case when tg_op = 'DELETE' then old.league_id else new.league_id end;
  if v_league_id = public.default_fantasy_league_id() then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  select status into v_status from public.leagues where id = v_league_id for update;
  if v_status = 'active' then
    perform public.capture_due_secondary_league_snapshots(v_league_id);
    if public.league_trade_airing_locked() then
      raise exception 'Roster changes are paused from airtime until this week is marked complete.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end $$;

create or replace function public.guard_league_trade_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Trades are paused from airtime until this week is marked complete.';
  end if;
  return new;
end $$;

-- Draft start is the only draft action barred by the airing. The draft pick
-- clock and manual/automatic picks still use the permissive draft lock.
create or replace function public.guard_league_draft_start_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'setup' and new.status = 'drafting'
    and public.league_trade_airing_locked() then
    raise exception 'A new draft cannot start after this week’s airing begins. Wait until the week is marked complete.';
  end if;
  return new;
end $$;

-- Keep the legacy original-league RPCs protected too. The shared league RPCs
-- are already guarded by league_trade_airing_locked and roster triggers.
do $$ begin
  if to_regprocedure('public.request_trade_before_completion_lock(uuid,uuid)') is null then
    alter function public.request_trade(uuid,uuid) rename to request_trade_before_completion_lock;
  end if;
  if to_regprocedure('public.counter_trade_before_completion_lock(uuid,uuid,uuid)') is null then
    alter function public.counter_trade(uuid,uuid,uuid) rename to counter_trade_before_completion_lock;
  end if;
  if to_regprocedure('public.accept_trade_before_completion_lock(uuid)') is null then
    alter function public.accept_trade(uuid) rename to accept_trade_before_completion_lock;
  end if;
  if to_regprocedure('public.swap_available_cast_member_into_team_before_completion_lock(uuid,uuid,uuid)') is null then
    alter function public.swap_available_cast_member_into_team(uuid,uuid,uuid)
      rename to swap_available_cast_member_into_team_before_completion_lock;
  end if;
end $$;

create or replace function public.request_trade(p_my_cast_member_id uuid,p_requested_cast_member_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Trades are paused from airtime until this week is marked complete.';
  end if;
  return public.request_trade_before_completion_lock(p_my_cast_member_id,p_requested_cast_member_id);
end $$;

create or replace function public.counter_trade(p_trade_id uuid,p_initiator_cast_member_id uuid,p_counterparty_cast_member_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Trades are paused from airtime until this week is marked complete.';
  end if;
  perform public.counter_trade_before_completion_lock(p_trade_id,p_initiator_cast_member_id,p_counterparty_cast_member_id);
end $$;

create or replace function public.accept_trade(p_trade_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Trades are paused from airtime until this week is marked complete.';
  end if;
  perform public.accept_trade_before_completion_lock(p_trade_id);
end $$;

create or replace function public.swap_available_cast_member_into_team(
  p_team_id uuid,p_incoming_cast_member_id uuid,p_outgoing_cast_member_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Roster changes are paused from airtime until this week is marked complete.';
  end if;
  perform public.swap_available_cast_member_into_team_before_completion_lock(
    p_team_id,p_incoming_cast_member_id,p_outgoing_cast_member_id);
end $$;

revoke all on function
  public.request_trade_before_completion_lock(uuid,uuid),
  public.counter_trade_before_completion_lock(uuid,uuid,uuid),
  public.accept_trade_before_completion_lock(uuid),
  public.swap_available_cast_member_into_team_before_completion_lock(uuid,uuid,uuid)
  from public,anon,authenticated;
revoke all on function
  public.request_trade(uuid,uuid),public.counter_trade(uuid,uuid,uuid),
  public.accept_trade(uuid),public.swap_available_cast_member_into_team(uuid,uuid,uuid)
  from public,anon;
grant execute on function
  public.request_trade(uuid,uuid),public.counter_trade(uuid,uuid,uuid),
  public.accept_trade(uuid),public.swap_available_cast_member_into_team(uuid,uuid,uuid)
  to authenticated;

commit;
