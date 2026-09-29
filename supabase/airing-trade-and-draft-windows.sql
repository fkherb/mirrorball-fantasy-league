-- Run after add-market-prediction-history-and-schedule.sql and the existing
-- secondary-league draft/trade migrations. Airing times are Eastern local time.
begin;

create or replace function public.league_trade_airing_locked(p_at timestamptz default clock_timestamp())
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.weeks w
    cross join lateral (values
      (w.air_date, w.air_start_time, w.air_end_time),
      (w.second_air_date, coalesce(w.second_air_start_time, w.air_start_time),
       coalesce(w.second_air_end_time, w.air_end_time))
    ) as airing(day, starts, ends)
    where airing.day is not null
      and p_at >= ((airing.day + airing.starts) at time zone 'America/New_York') - interval '2 hours'
      and p_at < ((airing.day + airing.ends) at time zone 'America/New_York') + interval '2 hours'
  );
$$;

create or replace function public.league_draft_airing_lock_start(p_at timestamptz default clock_timestamp())
returns timestamptz language sql stable security definer set search_path = '' as $$
  select min(((airing.day + airing.starts) at time zone 'America/New_York') - interval '15 minutes')
  from public.weeks w
  cross join lateral (values
    (w.air_date, w.air_start_time),
    (w.second_air_date, coalesce(w.second_air_start_time, w.air_start_time))
  ) as airing(day, starts)
  where not w.is_complete and airing.day is not null
    and p_at >= ((airing.day + airing.starts) at time zone 'America/New_York') - interval '15 minutes';
$$;

-- The weekly roster is fixed at the opening of the trade lock, not at
-- midnight on airing day. A pre-show visit must not save an early roster.
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
        - interval '2 hours'
  loop
    perform public.capture_secondary_league_week_snapshot(p_league_id, v_week.id);
  end loop;
end;
$$;

-- Guard the mutation itself, including old pages and direct RPC calls.
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
      raise exception 'Roster changes are paused from two hours before the airing until two hours after.';
    end if;
  elsif v_status = 'drafting' and public.league_draft_airing_lock_start() is not null then
    raise exception 'Draft picks are paused until this week is marked complete.';
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;

create or replace function public.guard_league_trade_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Trades are paused from two hours before the airing until two hours after.';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_league_trade_airing_window on public.league_trade_offers;
create trigger guard_league_trade_airing_window
before insert or update on public.league_trade_offers
for each row execute function public.guard_league_trade_airing_window();

create or replace function public.guard_league_draft_start_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'setup' and new.status = 'drafting'
     and new.id <> public.default_fantasy_league_id()
     and public.league_draft_airing_lock_start() is not null then
    raise exception 'Drafting is paused until this week is marked complete.';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_league_draft_start_airing_window on public.leagues;
create trigger guard_league_draft_start_airing_window
before update of status on public.leagues
for each row execute function public.guard_league_draft_start_airing_window();

create or replace function public.enforce_league_draft_pick_clock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_deadline timestamptz; v_paused_at timestamptz; v_timer_disabled boolean;
begin
  if public.league_draft_airing_lock_start() is not null then
    raise exception 'Draft picks are paused until this week is marked complete.';
  end if;
  select draft_pick_deadline_at, draft_paused_at, draft_timer_disabled
    into v_deadline, v_paused_at, v_timer_disabled
  from public.leagues where id = new.league_id;
  if v_paused_at is not null then raise exception 'This draft is paused.'; end if;
  if not coalesce(v_timer_disabled, false) and not new.is_auto_pick
     and v_deadline is not null and clock_timestamp() >= v_deadline then
    raise exception 'This turn has expired. Wait for the automatic pick.';
  end if;
  return new;
end;
$$;

alter table public.leagues
  add column if not exists draft_airing_paused_at timestamptz,
  add column if not exists draft_airing_seconds_remaining integer;
alter table public.leagues drop constraint if exists leagues_draft_airing_seconds_remaining_check;
alter table public.leagues add constraint leagues_draft_airing_seconds_remaining_check
  check (draft_airing_seconds_remaining between 0 and 120);

-- Preserve the current auto-pick implementation, wrapping it with the airing
-- pause. The wrapper owns the exposed RPC name; the old function is private.
do $$ begin
  if to_regprocedure('public.advance_league_draft_clock_without_airing_lock(uuid)') is null then
    execute 'alter function public.advance_league_draft_clock(uuid) rename to advance_league_draft_clock_without_airing_lock';
  end if;
end $$;
revoke all on function public.advance_league_draft_clock_without_airing_lock(uuid)
  from public, anon, authenticated;

create or replace function public.advance_league_draft_clock(p_league_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_lock_start timestamptz; v_pick_count integer;
begin
  if auth.uid() is not null and not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'League not found.';
  end if;
  v_lock_start := public.league_draft_airing_lock_start();
  if v_league.status = 'drafting' and v_lock_start is not null then
    if v_league.draft_airing_paused_at is null and not v_league.draft_timer_disabled then
      update public.leagues set
        draft_airing_paused_at = clock_timestamp(),
        draft_airing_seconds_remaining = least(120, greatest(0,
          coalesce(ceil(extract(epoch from v_league.draft_pick_deadline_at - v_lock_start))::integer, 120))),
        draft_pick_deadline_at = null
      where id = p_league_id;
    end if;
    select count(*) into v_pick_count from public.league_draft_picks where league_id = p_league_id;
    return jsonb_build_object('status', 'drafting', 'pick_count', v_pick_count,
      'deadline_at', null, 'server_now', clock_timestamp(), 'airing_locked', true);
  end if;
  if v_league.status = 'drafting' and v_league.draft_airing_paused_at is not null then
    update public.leagues set
      draft_pick_deadline_at = case when draft_paused_at is not null or draft_timer_disabled then null
        else clock_timestamp() + make_interval(secs => coalesce(draft_airing_seconds_remaining, 120)) end,
      draft_airing_paused_at = null,
      draft_airing_seconds_remaining = null
    where id = p_league_id;
  end if;
  return public.advance_league_draft_clock_without_airing_lock(p_league_id);
end;
$$;
revoke all on function public.advance_league_draft_clock(uuid) from public, anon;
grant execute on function public.advance_league_draft_clock(uuid) to authenticated;

create or replace function public.process_expired_league_drafts()
returns void language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid;
begin
  for v_league_id in select id from public.leagues
    where status = 'drafting' and not draft_timer_disabled
  loop
    perform public.advance_league_draft_clock(v_league_id);
  end loop;
end;
$$;

revoke all on function public.league_trade_airing_locked(timestamptz),
  public.league_draft_airing_lock_start(timestamptz),
  public.capture_due_secondary_league_snapshots(uuid),
  public.guard_league_trade_airing_window(),
  public.guard_league_draft_start_airing_window(),
  public.process_expired_league_drafts() from public, anon, authenticated;

commit;
notify pgrst, 'reload schema';
