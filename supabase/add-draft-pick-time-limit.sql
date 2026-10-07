-- add-draft-pick-time-limit.sql
-- Lets a commissioner choose the draft pick clock before the draft starts:
--   • autopick on/off  (existing leagues.draft_timer_disabled)
--   • seconds per pick (new leagues.draft_pick_seconds, default 120 = today's behaviour)
-- Run once in the Supabase SQL editor. Safe to re-run.
--
-- Every function below is copied from 20260929_live_public_baseline.sql with
-- only the hard-coded 2 minutes / 120 seconds replaced by draft_pick_seconds.
-- If any of these functions changed on the live database after that baseline,
-- merge by hand instead of running this file as-is.

begin;

alter table public.leagues
  add column if not exists draft_pick_seconds integer not null default 120;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'leagues_draft_pick_seconds_range') then
    alter table public.leagues add constraint leagues_draft_pick_seconds_range
      check (draft_pick_seconds between 15 and 86400);
  end if;
end $$;

-- Owner-only, before the draft starts.
create or replace function public.update_league_draft_settings(
  p_league_id uuid, p_timer_disabled boolean, p_pick_seconds integer
) returns void
language plpgsql security definer set search_path to ''
as $$
declare v_league public.leagues;
begin
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'League not found.';
  end if;
  if v_league.status <> 'setup' then
    raise exception 'Draft settings are locked once the draft starts.';
  end if;
  if p_timer_disabled is null then raise exception 'Choose whether autopick is on.'; end if;
  if p_pick_seconds is null or p_pick_seconds not between 15 and 86400 then
    raise exception 'Pick time must be between 15 seconds and 24 hours.';
  end if;
  update public.leagues set draft_timer_disabled = p_timer_disabled,
    draft_pick_seconds = p_pick_seconds, updated_at = clock_timestamp()
  where id = p_league_id;
end;
$$;
revoke all on function public.update_league_draft_settings(uuid, boolean, integer) from public, anon;
grant execute on function public.update_league_draft_settings(uuid, boolean, integer) to authenticated;

-- First pick's clock when the draft starts.
create or replace function public.set_league_draft_deadline() returns trigger
language plpgsql security definer set search_path to ''
as $$
begin
  if new.status = 'drafting' and old.status is distinct from 'drafting' then
    new.draft_pick_deadline_at := case when new.draft_timer_disabled then null
      else clock_timestamp() + make_interval(secs => coalesce(new.draft_pick_seconds, 120)) end;
  elsif new.status <> 'drafting' then
    new.draft_pick_deadline_at := null;
  end if;
  return new;
end;
$$;

-- Next pick's clock after every pick.
create or replace function public.advance_league_draft_deadline_after_pick() returns trigger
language plpgsql security definer set search_path to ''
as $$
declare v_total integer;
begin
  select league.roster_size * count(*)::integer into v_total
  from public.leagues league
  join public.league_draft_order draft_order on draft_order.league_id = league.id
  where league.id = new.league_id
  group by league.roster_size;
  update public.leagues set draft_pick_deadline_at =
    case when draft_timer_disabled or new.pick_number >= v_total then null
      else clock_timestamp() + make_interval(secs => coalesce(draft_pick_seconds, 120)) end,
    updated_at = clock_timestamp()
  where id = new.league_id and status = 'drafting';
  return null;
end;
$$;

-- Pause / resume keep the remaining time, capped at the league's own limit.
create or replace function public.set_league_draft_paused(p_league_id uuid, p_paused boolean) returns void
language plpgsql security definer set search_path to ''
as $$
declare v_league public.leagues; v_remaining integer; v_limit integer;
begin
  if p_paused is null then raise exception 'Choose whether to pause or resume the draft.'; end if;
  if not public.is_league_owner(p_league_id) then
    raise exception 'Only the league owner can pause or resume the draft.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status <> 'drafting' then
    raise exception 'Only an active draft can be paused or resumed.';
  end if;
  if v_league.draft_timer_disabled then
    raise exception 'Untimed drafts do not have a clock to pause.';
  end if;
  v_limit := coalesce(v_league.draft_pick_seconds, 120);
  if p_paused and v_league.draft_paused_at is null then
    v_remaining := least(v_limit, greatest(0, coalesce(ceil(extract(epoch from
      v_league.draft_pick_deadline_at - clock_timestamp()))::integer, v_limit)));
    update public.leagues set
      draft_seconds_remaining = v_remaining,
      draft_pick_deadline_at = null,
      draft_paused_at = clock_timestamp(),
      updated_at = clock_timestamp()
    where id = p_league_id;
  elsif not p_paused and v_league.draft_paused_at is not null then
    update public.leagues set
      draft_pick_deadline_at = clock_timestamp()
        + make_interval(secs => coalesce(v_league.draft_seconds_remaining, v_limit)),
      draft_paused_at = null,
      draft_seconds_remaining = null,
      updated_at = clock_timestamp()
    where id = p_league_id;
  end if;
end;
$$;

-- The show-night hold keeps the remaining time the same way.
create or replace function public.advance_league_draft_clock(p_league_id uuid) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_league public.leagues; v_lock_start timestamptz; v_pick_count integer; v_limit integer;
begin
  if auth.uid() is not null and not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'League not found.';
  end if;
  v_limit := coalesce(v_league.draft_pick_seconds, 120);
  v_lock_start := public.league_draft_airing_lock_start();
  if v_league.status = 'drafting' and v_lock_start is not null then
    if v_league.draft_airing_paused_at is null and not v_league.draft_timer_disabled then
      update public.leagues set
        draft_airing_paused_at = clock_timestamp(),
        draft_airing_seconds_remaining = least(v_limit, greatest(0,
          coalesce(ceil(extract(epoch from v_league.draft_pick_deadline_at - v_lock_start))::integer, v_limit))),
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
        else clock_timestamp() + make_interval(secs => coalesce(draft_airing_seconds_remaining, v_limit)) end,
      draft_airing_paused_at = null,
      draft_airing_seconds_remaining = null
    where id = p_league_id;
  end if;
  return public.advance_league_draft_clock_without_airing_lock(p_league_id);
end;
$$;

commit;
