


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."accept_trade"("p_trade_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
  v_competing public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'This trade is waiting for the other manager.'; end if;

  perform 1 from public.cast_members
    where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id)
    order by id for update;
  if (select fantasy_team_id from public.cast_members where id = v_trade.initiator_cast_member_id) is distinct from v_trade.initiator_team_id
     or (select fantasy_team_id from public.cast_members where id = v_trade.counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'A cast member changed teams after this offer was created. The trade can no longer be accepted.';
  end if;

  perform public.record_trade_history_event(v_trade, 'accepted');
  for v_competing in
    select * from public.trade_offers
    where id <> v_trade.id and (
      v_trade.initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
      or v_trade.counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
    ) for update
  loop
    perform public.record_trade_history_event(v_competing, 'invalidated');
  end loop;

  update public.cast_members
  set fantasy_team_id = case
    when id = v_trade.initiator_cast_member_id then v_trade.counterparty_team_id
    when id = v_trade.counterparty_cast_member_id then v_trade.initiator_team_id
  end
  where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id);

  delete from public.trade_offers
  where v_trade.initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
     or v_trade.counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id);
end;
$$;


ALTER FUNCTION "public"."accept_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activate_drafted_league_snapshots"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.status = 'active' and old.status = 'drafting'
    and new.id <> public.default_fantasy_league_id() then
    update public.leagues set scoring_starts_after_week = 0 where id = new.id;
    perform public.backfill_drafted_league_weeks(new.id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."activate_drafted_league_snapshots"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."advance_league_draft_clock"("p_league_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."advance_league_draft_clock"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."advance_league_draft_clock_without_airing_lock"("p_league_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league public.leagues; v_team_count integer; v_pick_count integer;
  v_round integer; v_position integer; v_team_id uuid; v_user_id uuid; v_cast_id uuid;
begin
  if auth.uid() is not null and not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'League not found.';
  end if;
  if v_league.status = 'drafting' and not v_league.draft_timer_disabled
     and v_league.draft_pick_deadline_at <= clock_timestamp() then
    select count(*) into v_team_count from public.league_draft_order
      where league_id = p_league_id;
    select count(*) into v_pick_count from public.league_draft_picks
      where league_id = p_league_id;
    if v_team_count < 1 then raise exception 'Draft order is missing.'; end if;
    if v_pick_count < v_team_count * v_league.roster_size then
      v_round := v_pick_count / v_team_count + 1;
      v_position := v_pick_count % v_team_count + 1;
      if v_round % 2 = 0 then v_position := v_team_count - v_position + 1; end if;
      select draft_order.fantasy_team_id into v_team_id
      from public.league_draft_order draft_order
      where draft_order.league_id = p_league_id and draft_order.draft_position = v_position;
      select member.user_id into v_user_id from public.league_members member
      where member.league_id = p_league_id and member.fantasy_team_id = v_team_id
        and member.status = 'active';
      select cast_member.id into v_cast_id from public.cast_members cast_member
      where not exists (select 1 from public.league_roster_assignments assignment
        where assignment.league_id = p_league_id
          and assignment.cast_member_id = cast_member.id)
        and public.league_pick_is_eligible(p_league_id, v_team_id, cast_member.id)
      order by random() limit 1;
      if v_team_id is null or v_user_id is null or v_cast_id is null then
        raise exception 'No eligible automatic pick remains. Check the league roster limits.';
      end if;
      insert into public.league_roster_assignments
        (league_id, cast_member_id, fantasy_team_id)
      values (p_league_id, v_cast_id, v_team_id);
      insert into public.league_draft_picks
        (league_id, pick_number, round_number, fantasy_team_id,
         cast_member_id, picked_by, is_auto_pick)
      values (p_league_id, v_pick_count + 1, v_round, v_team_id,
        v_cast_id, v_user_id, true);
      if v_pick_count + 1 = v_team_count * v_league.roster_size then
        update public.leagues set status = 'active', draft_completed_at = clock_timestamp(),
          scoring_starts_after_week = 0, updated_at = clock_timestamp()
        where id = p_league_id;
      end if;
    end if;
  end if;
  select * into v_league from public.leagues where id = p_league_id;
  select count(*) into v_pick_count from public.league_draft_picks
    where league_id = p_league_id;
  return jsonb_build_object('status', v_league.status,
    'pick_count', v_pick_count, 'deadline_at', v_league.draft_pick_deadline_at,
    'server_now', clock_timestamp());
end;
$$;


ALTER FUNCTION "public"."advance_league_draft_clock_without_airing_lock"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."advance_league_draft_deadline_after_pick"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_total integer;
begin
  select league.roster_size * count(*)::integer into v_total
  from public.leagues league
  join public.league_draft_order draft_order on draft_order.league_id = league.id
  where league.id = new.league_id
  group by league.roster_size;
  update public.leagues set draft_pick_deadline_at =
    case when draft_timer_disabled or new.pick_number >= v_total then null
      else clock_timestamp() + interval '2 minutes' end,
    updated_at = clock_timestamp()
  where id = new.league_id and status = 'drafting';
  return null;
end;
$$;


ALTER FUNCTION "public"."advance_league_draft_deadline_after_pick"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_default_league_scope"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.league_id is null then
    new.league_id := public.default_fantasy_league_id();
  end if;
  if new.league_id is null then raise exception 'The default fantasy league is missing.'; end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."apply_default_league_scope"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_trade_history_league_scope"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_history_league_id uuid;
begin
  if new.league_id is null then
    select league_id into v_history_league_id
    from public.fantasy_teams
    where id = coalesce(new.initiator_team_id, new.counterparty_team_id);
    new.league_id := v_history_league_id;
  end if;
  if new.league_id is null then new.league_id := public.default_fantasy_league_id(); end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."apply_trade_history_league_scope"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_trade_offer_league_scope"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_initiator_league_id uuid;
  v_counterparty_league_id uuid;
begin
  select league_id into v_initiator_league_id from public.fantasy_teams where id = new.initiator_team_id;
  select league_id into v_counterparty_league_id from public.fantasy_teams where id = new.counterparty_team_id;
  if v_initiator_league_id is null or v_counterparty_league_id is null then
    raise exception 'Both fantasy teams must belong to a league.';
  end if;
  if v_initiator_league_id is distinct from v_counterparty_league_id then
    raise exception 'Trades cannot cross fantasy leagues.';
  end if;
  new.league_id := v_initiator_league_id;
  return new;
end;
$$;


ALTER FUNCTION "public"."apply_trade_offer_league_scope"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_cast_members_to_team"("p_team_id" "uuid", "p_cast_member_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if not exists (select 1 from public.fantasy_teams where id = p_team_id) then raise exception 'Fantasy team not found.'; end if;
  if coalesce(array_length(p_cast_member_ids, 1), 0) = 0 then raise exception 'Choose at least one cast member.'; end if;
  if exists (select 1 from public.cast_members where id = any(p_cast_member_ids) and fantasy_team_id is not null) then
    raise exception 'One or more selected cast members is already assigned.';
  end if;
  update public.cast_members set fantasy_team_id = p_team_id where id = any(p_cast_member_ids);
  if not found then raise exception 'No cast members were updated.'; end if;
end;
$$;


ALTER FUNCTION "public"."assign_cast_members_to_team"("p_team_id" "uuid", "p_cast_member_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."backfill_drafted_league_weeks"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_week record;
begin
  for v_week in select id from public.weeks where is_complete order by number loop
    perform public.capture_secondary_league_week_snapshot(p_league_id, v_week.id);
  end loop;
end;
$$;


ALTER FUNCTION "public"."backfill_drafted_league_weeks"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_read_league"("p_league_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (select 1 from public.leagues where id = p_league_id and is_public)
    or public.is_league_member(p_league_id);
$$;


ALTER FUNCTION "public"."can_read_league"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_view_profile"("p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and (
    p_user_id = auth.uid()
    or exists (
      select 1 from public.league_members mine
      join public.league_members theirs on theirs.league_id = mine.league_id
      where mine.user_id = auth.uid() and mine.status = 'active'
        and theirs.user_id = p_user_id and theirs.status = 'active'
    )
    or exists (
      select 1 from public.league_invites invite
      where invite.invitee_id = p_user_id and invite.status = 'pending'
        and invite.expires_at > now()
        and public.is_league_owner(invite.league_id)
    )
  );
$$;


ALTER FUNCTION "public"."can_view_profile"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_league_invite"("p_invite_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league_id uuid;
begin
  select league_id into v_league_id from public.league_invites where id = p_invite_id;
  if not public.is_league_owner(v_league_id) then raise exception 'League owner access required.'; end if;
  update public.league_invites set status = 'cancelled', responded_at = now()
  where id = p_invite_id and status = 'pending';
end;
$$;


ALTER FUNCTION "public"."cancel_league_invite"("p_invite_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_my_team_id not in (v_trade.initiator_team_id, v_trade.counterparty_team_id) then
    raise exception 'This trade does not belong to your team.';
  end if;
  if v_trade.awaiting_team_id = v_my_team_id then
    raise exception 'This offer is waiting for your response and cannot be cancelled by your team.';
  end if;
  perform public.record_trade_history_event(v_trade, 'cancelled');
  delete from public.trade_offers where id = p_trade_id;
end;
$$;


ALTER FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."capture_due_secondary_league_snapshots"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."capture_due_secondary_league_snapshots"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."capture_secondary_league_week_snapshot"("p_league_id" "uuid", "p_week_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (select 1 from public.league_weekly_roster_snapshots
    where league_id = p_league_id and week_id = p_week_id) then return; end if;
  insert into public.league_weekly_roster_snapshots
    (league_id, week_id, cast_member_id, fantasy_team_id,
     cast_member_name, cast_role, appearance_points, manager_name, team_name)
  select league.id, week.id, cast_member.id, assignment.fantasy_team_id,
    cast_member.name,
    case when week.number <= eliminated_week.number
           and cast_member.role = 'Eliminated Star' then 'Star'
         when week.number <= eliminated_week.number
           and cast_member.role = 'Eliminated Pro' then 'Pro'
         else cast_member.role end,
    case when cast_member.is_hough then
      (select rate.appearance_points from public.league_role_rates rate
       join public.roles role on role.id = rate.role_id
       where rate.league_id = league.id and role.name = 'Hough')
    when cast_member.role = 'Surprise' then
      coalesce((select rate.appearance_points + 2
        from public.league_role_rates rate join public.roles role on role.id = rate.role_id
        where rate.league_id = league.id and role.name = cast_member.surprise_base_role),
        cast_member.custom_appearance_points)
    else (select rate.appearance_points from public.league_role_rates rate
      join public.roles role on role.id = rate.role_id
      where rate.league_id = league.id and role.name = case
        when week.number <= eliminated_week.number
          and cast_member.role = 'Eliminated Star' then 'Star'
        when week.number <= eliminated_week.number
          and cast_member.role = 'Eliminated Pro' then 'Pro'
        else cast_member.role end)
    end,
    team.manager_name, team.team_name
  from public.leagues league
  join public.weeks week on week.id = p_week_id
  cross join public.cast_members cast_member
  left join public.weeks eliminated_week on eliminated_week.id = cast_member.eliminated_week_id
  left join public.league_roster_assignments assignment
    on assignment.league_id = league.id and assignment.cast_member_id = cast_member.id
  left join public.fantasy_teams team on team.id = assignment.fantasy_team_id
  where league.id = p_league_id and league.status = 'active'
    and league.id <> public.default_fantasy_league_id()
    and week.number > league.scoring_starts_after_week
  on conflict (league_id, week_id, cast_member_id) do nothing;
end;
$$;


ALTER FUNCTION "public"."capture_secondary_league_week_snapshot"("p_league_id" "uuid", "p_week_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_balanced_draft_capacity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_managers integer; v_pros integer; v_stars integer; v_bonus integer;
  v_pro_limit integer; v_star_limit integer; v_bonus_share integer; v_flex integer;
begin
  if new.id = public.default_fantasy_league_id()
     or new.status <> 'drafting' or old.status = 'drafting' then return new; end if;
  select count(*) into v_managers from public.league_members
    where league_id = new.id and status = 'active';
  if v_managers not between 3 and 5 then
    raise exception 'Invite 3 to 5 managers before starting the draft.';
  end if;
  select count(*) filter (where role = 'Pro'),
    count(*) filter (where role = 'Star'),
    count(*) filter (where role not in ('Pro', 'Star'))
    into v_pros, v_stars, v_bonus from public.cast_members;
  v_pro_limit := v_pros / v_managers;
  v_star_limit := v_stars / v_managers;
  v_bonus_share := v_bonus / v_managers;
  v_flex := case when new.roster_size >
    v_pro_limit + v_star_limit + v_bonus_share then 1 else 0 end;
  if v_managers * new.roster_size > v_pros + v_stars + v_bonus
     or v_pro_limit + v_star_limit + v_bonus_share + v_flex < new.roster_size
     or (v_flex = 1 and v_pros + v_stars -
          v_managers * (v_pro_limit + v_star_limit) < v_managers) then
    raise exception 'This draft cannot fill every team under the current Pro/Star/Bonus limits.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."check_balanced_draft_capacity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_league_membership_capacity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_member_count integer; v_roster_size integer; v_manual boolean;
begin
  if new.status = 'active' and new.league_id <> public.default_fantasy_league_id() then
    if tg_op = 'UPDATE' and old.status = 'active' then return new; end if;
    perform 1 from public.leagues where id = new.league_id for update;
    select count(*) into v_member_count from public.league_members
      where league_id = new.league_id and status = 'active';
    if v_member_count >= 5 then
      raise exception 'This league is full (five managers maximum).';
    end if;
    select roster_size, roster_size_overridden into v_roster_size, v_manual
      from public.leagues where id = new.league_id;
    if v_manual and (v_member_count + 1) * v_roster_size >
      (select count(*) from public.cast_members) then
      raise exception 'The custom roster size is too large for another manager. The owner must reduce it first.';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."check_league_membership_capacity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_secondary_league_trade_role_limits"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_side integer; v_team_id uuid; v_outgoing_id uuid; v_incoming_id uuid;
  v_incoming_role text; v_outgoing_role text; v_current integer; v_limit integer;
begin
  if new.league_id = public.default_fantasy_league_id()
     or (select status from public.leagues where id = new.league_id) <> 'active' then
    return new;
  end if;
  for v_side in 1..2 loop
    v_team_id := case when v_side = 1 then new.initiator_team_id
      else new.counterparty_team_id end;
    v_outgoing_id := case when v_side = 1 then new.initiator_cast_member_id
      else new.counterparty_cast_member_id end;
    v_incoming_id := case when v_side = 1 then new.counterparty_cast_member_id
      else new.initiator_cast_member_id end;
    select role into v_incoming_role from public.cast_members where id = v_incoming_id;
    if v_incoming_role not in ('Pro', 'Star') then continue; end if;
    select role into v_outgoing_role from public.cast_members where id = v_outgoing_id;
    select count(*) into v_current from public.league_roster_assignments a
      join public.cast_members c on c.id = a.cast_member_id
      where a.league_id = new.league_id and a.fantasy_team_id = v_team_id
        and c.role = v_incoming_role;
    v_limit := public.league_category_limit(new.league_id, v_incoming_role);
    if v_outgoing_role = v_incoming_role then
      v_current := v_current - 1;
    end if;
    if v_current + 1 > v_limit then
      raise exception 'This trade would exceed the current % limit of % for one team. Choose a Bonus cast member instead.',
        lower(v_incoming_role), v_limit;
    end if;
  end loop;
  return new;
end;
$$;


ALTER FUNCTION "public"."check_secondary_league_trade_role_limits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_user_league_membership_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_count integer;
begin
  if new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' then
    if old.user_id = new.user_id and old.status = 'active' then return new; end if;
  end if;
  perform 1 from public.profiles where user_id = new.user_id for update;
  select count(*) into v_count from public.league_members
    where user_id = new.user_id and status = 'active';
  if v_count >= 5 then
    raise exception 'You can belong to at most five leagues. Leave or delete one before joining another.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."check_user_league_membership_limit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_league_cast_member"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_team_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to claim cast.'; end if;
  if p_league_id = public.default_fantasy_league_id() then
    select fantasy_team_id into v_team_id from public.league_members
    where league_id = p_league_id and user_id = auth.uid() and status = 'active';
    if v_team_id is null then raise exception 'League membership required.'; end if;
    if p_outgoing_cast_member_id is null then
      raise exception 'Choose a cast member to release.';
    end if;
    if public.league_trade_airing_locked() then
      raise exception 'Roster changes are paused from two hours before the airing until two hours after.';
    end if;
    perform public.swap_available_cast_member_into_team(
      v_team_id, p_incoming_cast_member_id, p_outgoing_cast_member_id);
    return;
  end if;
  perform public.claim_league_cast_member_without_default(
    p_league_id, p_incoming_cast_member_id, p_outgoing_cast_member_id);
end;
$$;


ALTER FUNCTION "public"."claim_league_cast_member"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_league_cast_member_without_default"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_league public.leagues;
  v_team_id uuid;
  v_team_count integer;
  v_pick_count integer;
  v_round integer;
  v_position integer;
  v_expected_team uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to claim cast.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id() then
    raise exception 'Use the original league roster controls for this league.';
  end if;
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null then raise exception 'League membership required.'; end if;
  if not exists (select 1 from public.cast_members where id = p_incoming_cast_member_id) then
    raise exception 'Cast member not found.';
  end if;
  if exists (select 1 from public.league_roster_assignments
             where league_id = p_league_id and cast_member_id = p_incoming_cast_member_id) then
    raise exception 'This cast member is already claimed.';
  end if;

  if v_league.status = 'drafting' then
    if p_outgoing_cast_member_id is not null then raise exception 'Draft picks do not release cast.'; end if;
    select count(*) into v_team_count from public.league_draft_order where league_id = p_league_id;
    select count(*) into v_pick_count from public.league_draft_picks where league_id = p_league_id;
    v_round := v_pick_count / v_team_count + 1;
    if v_round > v_league.roster_size then raise exception 'The draft is complete.'; end if;
    v_position := (v_pick_count % v_team_count) + 1;
    if v_round % 2 = 0 then v_position := v_team_count - v_position + 1; end if;
    select fantasy_team_id into v_expected_team from public.league_draft_order
    where league_id = p_league_id and draft_position = v_position;
    if v_expected_team is distinct from v_team_id then raise exception 'It is not your turn to draft.'; end if;
    insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
    values (p_league_id, p_incoming_cast_member_id, v_team_id);
    insert into public.league_draft_picks
      (league_id, pick_number, round_number, fantasy_team_id, cast_member_id, picked_by)
    values (p_league_id, v_pick_count + 1, v_round, v_team_id,
      p_incoming_cast_member_id, auth.uid());
    if v_pick_count + 1 = v_team_count * v_league.roster_size then
      update public.leagues set status = 'active', draft_completed_at = now(),
        scoring_starts_after_week = coalesce((select max(number) from public.weeks where is_complete), 0),
        updated_at = now() where id = p_league_id;
    end if;
  elsif v_league.status = 'active' then
    if p_outgoing_cast_member_id is null then raise exception 'Choose a cast member to release.'; end if;
    if p_incoming_cast_member_id = p_outgoing_cast_member_id then raise exception 'Choose different cast members.'; end if;
    if not exists (select 1 from public.league_roster_assignments
      where league_id = p_league_id and fantasy_team_id = v_team_id
        and cast_member_id = p_outgoing_cast_member_id) then
      raise exception 'The outgoing cast member is not on your team.';
    end if;
    if exists (select 1 from public.league_trade_offers offer
      where offer.league_id = p_league_id and p_outgoing_cast_member_id in
        (offer.initiator_cast_member_id, offer.counterparty_cast_member_id)) then
      raise exception 'This cast member has an active trade offer.';
    end if;
    delete from public.league_roster_assignments
    where league_id = p_league_id and cast_member_id = p_outgoing_cast_member_id;
    insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
    values (p_league_id, p_incoming_cast_member_id, v_team_id);
  else
    raise exception 'Claims open when the draft starts.';
  end if;
end;
$$;


ALTER FUNCTION "public"."claim_league_cast_member_without_default"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_week"("p_week_id" "uuid", "p_eliminated_partnership_ids" "uuid"[] DEFAULT '{}'::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_week public.weeks%rowtype;
  v_expected_eliminations integer;
  v_expected_judges integer;
begin
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if v_week.is_complete then raise exception 'This week is already complete.'; end if;

  v_expected_eliminations := case when v_week.is_finale then 0 when v_week.double_elimination then 2 else 1 end;
  v_expected_judges := 3 + case when nullif(trim(v_week.guest_judge_name), '') is null then 0 else 1 end;
  if coalesce(cardinality(p_eliminated_partnership_ids), 0) <> v_expected_eliminations then
    raise exception 'Choose exactly % eliminated couple(s) before completing this week.', v_expected_eliminations;
  end if;
  if (select count(distinct partnership_id) from unnest(p_eliminated_partnership_ids) as chosen(partnership_id)) <> v_expected_eliminations then
    raise exception 'Each eliminated couple must be different.';
  end if;
  if exists (
    select 1 from unnest(p_eliminated_partnership_ids) as chosen(partnership_id)
    where not exists (
      select 1 from public.dances as d where d.week_id = p_week_id
        and d.kind = 'competitive' and d.partnership_id = chosen.partnership_id
    )
  ) then raise exception 'An eliminated couple must have a competitive dance recorded in that week.'; end if;
  if exists (
    select 1 from public.dances as d where d.week_id = p_week_id and d.kind = 'competitive'
      and (select count(*) from public.dance_judge_scores as s where s.dance_id = d.id) <> v_expected_judges
  ) then raise exception 'Every competitive dance needs exactly % judge score(s) before completion.', v_expected_judges; end if;

  insert into public.weekly_roster_snapshots (
    week_id, cast_member_id, fantasy_team_id, cast_member_name, cast_role, manager_name, team_name, appearance_points
  )
  select p_week_id, c.id, c.fantasy_team_id, c.name,
    case
      when c.eliminated_week_id = p_week_id and c.role = 'Eliminated Star' then 'Star'
      when c.eliminated_week_id = p_week_id and c.role = 'Eliminated Pro' then 'Pro'
      else c.role
    end,
    t.manager_name, t.team_name,
    case when c.role = 'Surprise' then c.custom_appearance_points else null end
  from public.cast_members as c
  left join public.fantasy_teams as t on t.id = c.fantasy_team_id
  on conflict (week_id, cast_member_id) do update set
    fantasy_team_id = excluded.fantasy_team_id,
    cast_member_name = excluded.cast_member_name,
    cast_role = excluded.cast_role,
    manager_name = excluded.manager_name,
    team_name = excluded.team_name,
    appearance_points = excluded.appearance_points;

  insert into public.weekly_role_rates (week_id, role, appearance_points)
  select p_week_id, r.name, r.appearance_points
  from public.roles as r where r.name <> 'Surprise'
  on conflict (week_id, role) do nothing;

  update public.cast_members as c set role = 'Eliminated Star', eliminated_week_id = p_week_id
  from public.partnerships as pair where pair.id = any(p_eliminated_partnership_ids) and c.id = pair.star_id;
  update public.cast_members as c set role = 'Eliminated Pro', eliminated_week_id = p_week_id
  from public.partnerships as pair where pair.id = any(p_eliminated_partnership_ids) and c.id = pair.pro_id;
  update public.weeks set is_complete = true where id = p_week_id;
end;
$$;


ALTER FUNCTION "public"."complete_week"("p_week_id" "uuid", "p_eliminated_partnership_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."counter_trade"("p_trade_id" "uuid", "p_initiator_cast_member_id" "uuid", "p_counterparty_cast_member_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
  v_changed_count integer;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.status <> 'pending' or v_trade.awaiting_team_id <> v_my_team_id or v_trade.counterparty_team_id <> v_my_team_id then
    raise exception 'This trade cannot be countered by your team.';
  end if;

  v_changed_count :=
    (case when p_initiator_cast_member_id is distinct from v_trade.initiator_cast_member_id then 1 else 0 end) +
    (case when p_counterparty_cast_member_id is distinct from v_trade.counterparty_cast_member_id then 1 else 0 end);
  if v_changed_count <> 1 then raise exception 'A counter must change exactly one side of the offer.'; end if;
  if p_initiator_cast_member_id = p_counterparty_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform 1 from public.cast_members where id in (p_initiator_cast_member_id, p_counterparty_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = p_initiator_cast_member_id) is distinct from v_trade.initiator_team_id then
    raise exception 'The requested cast member is no longer on the original manager’s team.';
  end if;
  if (select fantasy_team_id from public.cast_members where id = p_counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'The cast member you are offering is no longer on your team.';
  end if;
  if exists (
    select 1 from public.trade_offers
    where id <> p_trade_id
      and (
        p_initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
        or p_counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
      )
  ) then
    raise exception 'One of these cast members is already part of another active trade offer.';
  end if;

  -- Preserve the offer that was declined before replacing it with the counter.
  perform public.record_trade_history_event(v_trade, 'countered');
  update public.trade_offers
  set initiator_cast_member_id = p_initiator_cast_member_id,
      counterparty_cast_member_id = p_counterparty_cast_member_id,
      status = 'countered',
      awaiting_team_id = initiator_team_id,
      updated_at = now(),
      expires_at = now() + interval '48 hours'
  where id = p_trade_id;
end;
$$;


ALTER FUNCTION "public"."counter_trade"("p_trade_id" "uuid", "p_initiator_cast_member_id" "uuid", "p_counterparty_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_fantasy_league"("p_name" "text", "p_roster_size" integer DEFAULT 11) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_id uuid := gen_random_uuid();
  v_profile public.profiles;
  v_team_id uuid;
  v_name text := trim(coalesce(p_name, ''));
  v_created_count integer;
  v_membership_count integer;
begin
  if auth.uid() is null then raise exception 'Sign in to create a league.'; end if;
  select * into v_profile from public.profiles where user_id = auth.uid() for update;
  if v_profile.user_id is null or not v_profile.onboarding_completed then
    raise exception 'Confirm your profile before creating a league.';
  end if;
  select count(*) into v_created_count from public.leagues
    where created_by = auth.uid() and id <> public.default_fantasy_league_id();
  if v_created_count >= 2 then
    raise exception 'You can create at most two leagues. Delete one before creating another.';
  end if;
  select count(*) into v_membership_count from public.league_members
    where user_id = auth.uid() and status = 'active';
  if v_membership_count >= 5 then
    raise exception 'You can belong to at most five leagues. Leave or delete one before creating another.';
  end if;
  if char_length(v_name) not between 1 and 80 then
    raise exception 'League name must be 1–80 characters.';
  end if;
  if p_roster_size not between 1 and 30 then
    raise exception 'Roster size must be 1–30.';
  end if;

  insert into public.leagues (id, slug, name, created_by, status, roster_size)
  values (v_id, 'league-' || replace(v_id::text, '-', ''), v_name, auth.uid(), 'setup', p_roster_size);
  insert into public.fantasy_teams (league_id, manager_name, team_name)
  values (v_id, v_profile.display_name,
    left(split_part(v_profile.display_name, ' ', 1), 72) || '''s Team') returning id into v_team_id;
  insert into public.league_members
    (league_id, user_id, fantasy_team_id, role, first_name, last_name, is_commissioner)
  values (v_id, auth.uid(), v_team_id, 'owner',
    split_part(v_profile.display_name, ' ', 1),
    nullif(trim(substr(v_profile.display_name,
      char_length(split_part(v_profile.display_name, ' ', 1)) + 1)), ''), false);
  insert into public.league_role_rates (league_id, role_id, appearance_points)
  select v_id, role.id, coalesce(default_rate.appearance_points, role.appearance_points)
  from public.roles role
  left join public.league_role_rates default_rate
    on default_rate.league_id = public.default_fantasy_league_id()
   and default_rate.role_id = role.id;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."create_fantasy_league"("p_name" "text", "p_roster_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_league_invite"("p_league_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_token text;
  v_code text;
  v_bytes bytea;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_i integer;
  v_tries integer;
begin
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are available before the draft starts.';
  end if;
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  for v_tries in 1..10 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for v_i in 0..5 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, v_i) % 32) + 1, 1);
    end loop;
    exit when not exists (
      select 1 from public.league_invite_links where code_hash = md5(v_code)
    );
  end loop;
  if v_tries = 10 and exists (
    select 1 from public.league_invite_links where code_hash = md5(v_code)
  ) then raise exception 'Could not generate a unique invite code. Please try again.'; end if;
  insert into public.league_invite_links (league_id, token_hash, code_hash, created_by)
  values (p_league_id, md5(v_token), md5(v_code), auth.uid());
  return jsonb_build_object('token', v_token, 'code', v_code);
end;
$$;


ALTER FUNCTION "public"."create_league_invite"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_profile_for_auth_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_display_name text;
  v_seed text;
  v_username text;
begin
  v_display_name := public.profile_display_name_from_auth(new);
  v_seed := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'first_name'), ''),
    nullif(split_part(v_display_name, ' ', 1), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'user'
  );

  -- The unique index is the final concurrency guard. Retry with the next suffix
  -- if two signups choose the same base between lookup and insert.
  loop
    v_username := public.next_profile_username(v_seed, new.id);
    begin
      insert into public.profiles (user_id, username, display_name)
      values (new.id, v_username, v_display_name)
      on conflict (user_id) do nothing;
      exit;
    exception when unique_violation then
      continue;
    end;
  end loop;
  return new;
end;
$$;


ALTER FUNCTION "public"."create_profile_for_auth_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_league_team_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select fantasy_team_id from public.league_members
  where league_id = public.default_fantasy_league_id()
    and user_id = auth.uid() and status = 'active' limit 1;
$$;


ALTER FUNCTION "public"."current_league_team_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."default_fantasy_league_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select id from public.leagues where slug = 'dwts-fantasy-league' limit 1;
$$;


ALTER FUNCTION "public"."default_fantasy_league_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_cast_member_atomic"("p_cast_member_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  perform 1 from public.cast_members where id = p_cast_member_id for update;
  if not found then raise exception 'Cast member not found.'; end if;
  if exists (select 1 from public.weekly_roster_snapshots where cast_member_id = p_cast_member_id)
     or exists (select 1 from public.dance_appearances where cast_member_id = p_cast_member_id)
     or exists (
       select 1 from public.dances d join public.partnerships p on p.id = d.partnership_id
       where p_cast_member_id in (p.star_id, p.pro_id)
     ) then
    raise exception 'This cast member is part of league history and cannot be deleted. Keep the record and update its assignment instead.';
  end if;
  delete from public.partnerships where p_cast_member_id in (star_id, pro_id);
  delete from public.cast_members where id = p_cast_member_id;
end;
$$;


ALTER FUNCTION "public"."delete_cast_member_atomic"("p_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_fantasy_league"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_league_id is null or p_league_id = public.default_fantasy_league_id() then
    raise exception 'The original league cannot be deleted.';
  end if;
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if not found then raise exception 'League not found.'; end if;

  delete from public.league_invites where league_id = p_league_id;
  delete from public.league_invite_links where league_id = p_league_id;
  delete from public.league_trade_events where league_id = p_league_id;
  delete from public.league_trade_offers where league_id = p_league_id;
  delete from public.trade_history where league_id = p_league_id;
  delete from public.trade_offers where league_id = p_league_id;
  delete from public.league_weekly_roster_snapshots where league_id = p_league_id;
  delete from public.weekly_roster_snapshots where league_id = p_league_id;
  delete from public.league_draft_picks where league_id = p_league_id;
  delete from public.league_draft_order where league_id = p_league_id;
  delete from public.league_roster_assignments where league_id = p_league_id;
  delete from public.league_role_rates where league_id = p_league_id;
  delete from public.league_settings where league_id = p_league_id;
  delete from public.roster_history history using public.fantasy_teams team
    where history.fantasy_team_id = team.id and team.league_id = p_league_id;
  delete from public.league_members where league_id = p_league_id;
  delete from public.fantasy_teams where league_id = p_league_id;
  delete from public.leagues where id = p_league_id;
end;
$$;


ALTER FUNCTION "public"."delete_fantasy_league"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deny_trade"("p_trade_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'Only the manager reviewing this offer can deny it.'; end if;
  perform public.record_trade_history_event(v_trade, 'denied');
  delete from public.trade_offers where id = p_trade_id;
end;
$$;


ALTER FUNCTION "public"."deny_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dismiss_league_trade_result"("p_event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_event public.league_trade_events; v_team_id uuid;
begin
  select * into v_event from public.league_trade_events where id = p_event_id for update;
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = v_event.league_id and user_id = auth.uid() and status = 'active';
  if v_event.id is null or v_event.notification_team_id is distinct from v_team_id
    or v_event.dismissed_at is not null then raise exception 'Trade result is unavailable.'; end if;
  update public.league_trade_events set dismissed_at = now() where id = p_event_id;
end;
$$;


ALTER FUNCTION "public"."dismiss_league_trade_result"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dismiss_trade_result"("p_history_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;

  update public.trade_history
  set dismissed_at = now()
  where id = p_history_id
    and notification_team_id = v_my_team_id
    and dismissed_at is null;

  if not found then raise exception 'This trade result is no longer available.'; end if;
end;
$$;


ALTER FUNCTION "public"."dismiss_trade_result"("p_history_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_league_draft_pick_clock"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."enforce_league_draft_pick_clock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_league_draft_role_reserves"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_role text; v_team_role_count integer;
begin
  if new.league_id = public.default_fantasy_league_id()
     or (select status from public.leagues where id = new.league_id) <> 'drafting' then
    return new;
  end if;
  select role into v_role from public.cast_members where id = new.cast_member_id;
  if v_role not in ('Pro', 'Star') then return new; end if;
  select count(*) into v_team_role_count from public.league_roster_assignments a
    join public.cast_members c on c.id = a.cast_member_id
    where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
      and c.role = v_role;
  if v_team_role_count > public.league_category_limit(new.league_id, v_role)
     and public.league_unreserved_active_role_count(new.league_id, v_role) < 0 then
    raise exception 'That % is reserved for another manager’s unfilled draft slot.',
      lower(v_role);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_league_draft_role_reserves"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_member_profile_name"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_display_name text;
begin
  select display_name into v_display_name from public.profiles where user_id = new.user_id;
  if v_display_name is not null then
    new.first_name := left(split_part(v_display_name, ' ', 1), 40);
    new.last_name := nullif(left(trim(substr(v_display_name, char_length(split_part(v_display_name, ' ', 1)) + 1)), 50), '');
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_member_profile_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_preset_league_roster_size"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.id <> public.default_fantasy_league_id() and new.status = 'setup' then
    new.roster_size := public.suggest_league_roster_size(
      (select count(*)::integer from public.league_members
       where league_id = new.id and status = 'active'));
    new.roster_size_overridden := false;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_preset_league_roster_size"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_secondary_league_category_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_status text; v_role text; v_category text;
  v_total integer; v_active_total integer; v_limit integer; v_flex integer;
begin
  if new.league_id = public.default_fantasy_league_id() then return new; end if;
  select status into v_status from public.leagues where id = new.league_id;
  if v_status not in ('drafting', 'active') then return new; end if;
  if tg_op = 'UPDATE' and new.fantasy_team_id is not distinct from old.fantasy_team_id then return new; end if;
  select role into v_role from public.cast_members where id = new.cast_member_id;
  v_category := public.league_cast_category(v_role);
  if v_category = 'Bonus' then
    if v_status = 'drafting' then
      select count(*) into v_total from public.league_roster_assignments a
        join public.cast_members c on c.id = a.cast_member_id
        where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
          and c.role not in ('Pro', 'Star');
      if v_total > public.league_bonus_draft_limit(new.league_id) then
        raise exception 'This draft team has filled its Bonus spots.';
      end if;
    end if;
    return new;
  end if;
  select count(*) into v_total from public.league_roster_assignments a
    join public.cast_members c on c.id = a.cast_member_id
    where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
      and c.role = v_role;
  v_limit := public.league_category_limit(new.league_id, v_role);
  v_flex := case when v_status = 'drafting' then public.league_flex_allowance(new.league_id) else 0 end;
  select count(*) into v_active_total from public.league_roster_assignments a
    join public.cast_members c on c.id = a.cast_member_id
    where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
      and c.role in ('Pro', 'Star');
  if v_total > v_limit + v_flex
     or v_active_total > public.league_category_limit(new.league_id, 'Pro')
       + public.league_category_limit(new.league_id, 'Star') + v_flex then
    raise exception 'This team may add no more active % cast (limit %, current %).',
      lower(v_role), v_limit + v_flex, v_total;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_secondary_league_category_limit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_team_profile_name"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_display_name text;
begin
  select profile.display_name into v_display_name
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  where member.fantasy_team_id = new.id
  limit 1;
  if v_display_name is not null then new.manager_name := v_display_name; end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_team_profile_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_league_trade_offers"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_offer public.league_trade_offers;
begin
  for v_offer in select * from public.league_trade_offers
    where league_id = p_league_id and expires_at <= now() for update
  loop
    perform public.record_league_trade_event(v_offer, 'expired');
    delete from public.league_trade_offers where id = v_offer.id;
  end loop;
end;
$$;


ALTER FUNCTION "public"."expire_league_trade_offers"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."expire_trade_offers_locked"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_trade public.trade_offers;
  v_count integer := 0;
begin
  for v_trade in
    select * from public.trade_offers where expires_at <= now() for update
  loop
    perform public.record_trade_history_event(v_trade, 'expired');
    delete from public.trade_offers where id = v_trade.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."expire_trade_offers_locked"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_league_draft_readiness"("p_league_id" "uuid") RETURNS TABLE("user_id" "uuid", "ready_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  return query select member.user_id, member.draft_ready_at
  from public.league_members member
  where member.league_id = p_league_id and member.status = 'active';
end;
$$;


ALTER FUNCTION "public"."get_league_draft_readiness"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_league_invite"("p_league_id" "uuid", "p_refresh" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_link public.league_invite_links;
begin
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are unavailable after the draft starts.';
  end if;
  select * into v_link from public.league_invite_links
  where league_id = p_league_id and revoked_at is null for update;
  if p_refresh or v_link.id is null or v_link.expires_at <= now()
     or v_link.token_value is null or v_link.code_value is null then
    perform public.rotate_league_invite_credentials(p_league_id, auth.uid());
    select * into v_link from public.league_invite_links
    where league_id = p_league_id and revoked_at is null;
  end if;
  return jsonb_build_object('token', v_link.token_value, 'code', v_link.code_value,
                            'expires_at', v_link.expires_at);
end;
$$;


ALTER FUNCTION "public"."get_league_invite"("p_league_id" "uuid", "p_refresh" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_league_team_managers"() RETURNS TABLE("fantasy_team_id" "uuid", "user_id" "uuid", "username" "text", "display_name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select member.fantasy_team_id, profile.user_id, profile.username, profile.display_name
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  where member.league_id = public.default_fantasy_league_id()
    and member.fantasy_team_id is not null;
$$;


ALTER FUNCTION "public"."get_league_team_managers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_account_context"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'profile', (select to_jsonb(profile) from public.profiles profile where profile.user_id = auth.uid()),
    'membership', (
      select to_jsonb(member)
      from public.league_members member
      where member.user_id = auth.uid()
        and member.league_id = public.default_fantasy_league_id()
      limit 1
    ),
    'team_name', (
      select team.team_name
      from public.league_members member
      join public.fantasy_teams team on team.id = member.fantasy_team_id
      where member.user_id = auth.uid()
        and member.league_id = public.default_fantasy_league_id()
      limit 1
    )
  ) end;
$$;


ALTER FUNCTION "public"."get_my_account_context"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_league_invites"() RETURNS TABLE("id" "uuid", "league_id" "uuid", "league_name" "text", "inviter_username" "text", "created_at" timestamp with time zone, "expires_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select invite.id, invite.league_id, league.name, profile.username,
    invite.created_at, invite.expires_at
  from public.league_invites invite
  join public.leagues league on league.id = invite.league_id
  join public.profiles profile on profile.user_id = invite.inviter_id
  where invite.invitee_id = auth.uid() and invite.status = 'pending'
    and invite.expires_at > now()
  order by invite.created_at desc;
$$;


ALTER FUNCTION "public"."get_my_league_invites"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_league_trades"("p_league_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_team_id uuid; v_offers jsonb; v_events jsonb; v_notifications jsonb;
begin
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null then raise exception 'League membership required.'; end if;
  perform public.expire_league_trade_offers(p_league_id);
  select coalesce(jsonb_agg(to_jsonb(offer) order by offer.updated_at desc), '[]'::jsonb)
    into v_offers from public.league_trade_offers offer
    where offer.league_id = p_league_id
      and v_team_id in (offer.initiator_team_id, offer.counterparty_team_id);
  select coalesce(jsonb_agg(to_jsonb(event) order by event.event_at desc), '[]'::jsonb)
    into v_events from public.league_trade_events event
    where event.league_id = p_league_id
      and v_team_id in (event.initiator_team_id, event.counterparty_team_id)
      and (event.notification_team_id is distinct from v_team_id or event.dismissed_at is not null);
  select coalesce(jsonb_agg(to_jsonb(event) order by event.event_at desc), '[]'::jsonb)
    into v_notifications from public.league_trade_events event
    where event.league_id = p_league_id and event.notification_team_id = v_team_id
      and event.dismissed_at is null;
  return jsonb_build_object('offers', v_offers, 'history', v_events, 'notifications', v_notifications);
end;
$$;


ALTER FUNCTION "public"."get_my_league_trades"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_leagues"() RETURNS TABLE("league_id" "uuid", "name" "text", "status" "text", "roster_size" integer, "member_role" "text", "fantasy_team_id" "uuid", "team_name" "text", "is_public" boolean, "scoring_starts_after_week" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select league.id, league.name, league.status, league.roster_size,
    member.role, member.fantasy_team_id, team.team_name,
    league.is_public, league.scoring_starts_after_week
  from public.league_members member
  join public.leagues league on league.id = member.league_id
  left join public.fantasy_teams team on team.id = member.fantasy_team_id
  where member.user_id = auth.uid() and member.status = 'active'
  order by member.joined_at, league.name;
$$;


ALTER FUNCTION "public"."get_my_leagues"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."trade_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trade_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "initiator_team_id" "uuid",
    "counterparty_team_id" "uuid",
    "initiator_team_name" "text" NOT NULL,
    "counterparty_team_name" "text" NOT NULL,
    "initiator_cast_member_id" "uuid",
    "counterparty_cast_member_id" "uuid",
    "initiator_cast_member_name" "text" NOT NULL,
    "counterparty_cast_member_name" "text" NOT NULL,
    "event_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "notification_team_id" "uuid",
    "dismissed_at" timestamp with time zone,
    CONSTRAINT "trade_history_event_type_check" CHECK (("event_type" = ANY (ARRAY['countered'::"text", 'accepted'::"text", 'denied'::"text", 'expired'::"text", 'cancelled'::"text", 'invalidated'::"text"]))),
    CONSTRAINT "trade_history_notification_event_check" CHECK ((("notification_team_id" IS NULL) OR ("event_type" = ANY (ARRAY['accepted'::"text", 'denied'::"text"]))))
);


ALTER TABLE "public"."trade_history" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_trade_history"() RETURNS SETOF "public"."trade_history"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  return query
    select history.*
    from public.trade_history as history
    where (history.initiator_team_id = v_my_team_id or history.counterparty_team_id = v_my_team_id)
      and (
        history.notification_team_id is distinct from v_my_team_id
        or history.dismissed_at is not null
      )
    order by history.event_at desc;
end;
$$;


ALTER FUNCTION "public"."get_my_trade_history"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trade_offers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "initiator_team_id" "uuid" NOT NULL,
    "counterparty_team_id" "uuid" NOT NULL,
    "initiator_cast_member_id" "uuid" NOT NULL,
    "counterparty_cast_member_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "awaiting_team_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '48:00:00'::interval) NOT NULL,
    "league_id" "uuid" NOT NULL,
    CONSTRAINT "trade_offers_check" CHECK (("initiator_team_id" <> "counterparty_team_id")),
    CONSTRAINT "trade_offers_check1" CHECK (("initiator_cast_member_id" <> "counterparty_cast_member_id")),
    CONSTRAINT "trade_offers_check2" CHECK ((("awaiting_team_id" = "initiator_team_id") OR ("awaiting_team_id" = "counterparty_team_id"))),
    CONSTRAINT "trade_offers_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'countered'::"text"])))
);


ALTER TABLE "public"."trade_offers" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_trade_offers"() RETURNS SETOF "public"."trade_offers"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  return query
    select offer.* from public.trade_offers offer
    where offer.initiator_team_id = v_my_team_id or offer.counterparty_team_id = v_my_team_id
    order by offer.updated_at desc;
end;
$$;


ALTER FUNCTION "public"."get_my_trade_offers"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_trade_result_notifications"() RETURNS SETOF "public"."trade_history"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  return query
    select history.*
    from public.trade_history as history
    where history.notification_team_id = v_my_team_id
      and history.dismissed_at is null
      and history.event_type in ('accepted', 'denied')
    order by history.event_at desc;
end;
$$;


ALTER FUNCTION "public"."get_my_trade_result_notifications"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_default_legacy_trade_path"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league_id uuid;
begin
  select league_id into v_league_id from public.fantasy_teams
  where id = new.initiator_team_id;
  if v_league_id = public.default_fantasy_league_id()
     and (select shared_workspace_enabled from public.leagues where id = v_league_id) then
    raise exception 'This league now uses the updated trade center. Reload the page.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_default_legacy_trade_path"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_default_shared_trade_path"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.league_id = public.default_fantasy_league_id()
     and not (select shared_workspace_enabled from public.leagues where id = new.league_id) then
    raise exception 'This league has not switched to the updated trade center yet.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_default_shared_trade_path"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_league_draft_start_airing_window"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if old.status = 'setup' and new.status = 'drafting'
     and new.id <> public.default_fantasy_league_id()
     and public.league_draft_airing_lock_start() is not null then
    raise exception 'Drafting is paused until this week is marked complete.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_league_draft_start_airing_window"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_league_trade_airing_window"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if public.league_trade_airing_locked() then
    raise exception 'Trades are paused from two hours before the airing until two hours after.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."guard_league_trade_airing_window"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_secondary_league_roster_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."guard_secondary_league_roster_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."initialize_league_invite_credentials"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.role = 'owner' and new.status = 'active'
     and (select status from public.leagues where id = new.league_id) = 'setup'
     and not exists (select 1 from public.league_invite_links
                     where league_id = new.league_id and revoked_at is null) then
    perform public.rotate_league_invite_credentials(new.league_id, new.user_id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."initialize_league_invite_credentials"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invite_username"("p_league_id" "uuid", "p_username" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_invitee uuid; v_id uuid;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are available before the draft starts.';
  end if;
  select user_id into v_invitee from public.profiles
  where username = lower(trim(coalesce(p_username, '')));
  if v_invitee is null then raise exception 'Username not found.'; end if;
  if exists (select 1 from public.league_members where league_id = p_league_id and user_id = v_invitee) then
    raise exception 'That person already belongs to this league.';
  end if;
  update public.league_invites set status = 'cancelled', responded_at = now()
  where league_id = p_league_id and invitee_id = v_invitee
    and status = 'pending' and expires_at <= now();
  insert into public.league_invites (league_id, inviter_id, invitee_id)
  values (p_league_id, auth.uid(), v_invitee) returning id into v_id;
  return v_id;
exception when unique_violation then raise exception 'That person already has a pending invitation.';
end;
$$;


ALTER FUNCTION "public"."invite_username"("p_league_id" "uuid", "p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_league_commissioner"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1 from public.league_members
    where league_id = public.default_fantasy_league_id()
      and user_id = auth.uid() and status = 'active' and role = 'owner'
  );
$$;


ALTER FUNCTION "public"."is_league_commissioner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_league_member"("p_league_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and exists (
    select 1 from public.league_members
    where league_id = p_league_id and user_id = auth.uid() and status = 'active'
  );
$$;


ALTER FUNCTION "public"."is_league_member"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_league_owner"("p_league_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select auth.uid() is not null and exists (
    select 1 from public.league_members
    where league_id = p_league_id and user_id = auth.uid()
      and role = 'owner' and status = 'active'
  );
$$;


ALTER FUNCTION "public"."is_league_owner"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_platform_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.platform_admins
    where user_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."is_platform_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_league_from_invite"("p_league_id" "uuid", "p_user_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_profile public.profiles; v_team_id uuid; v_status text;
begin
  if p_user_id is distinct from auth.uid() then raise exception 'You can only join as yourself.'; end if;
  select status into v_status from public.leagues where id = p_league_id for update;
  if v_status is null or v_status = 'archived' then raise exception 'League is unavailable.'; end if;
  if v_status <> 'setup' then raise exception 'This league has already started its draft.'; end if;
  if exists (select 1 from public.league_members where league_id = p_league_id and user_id = p_user_id) then
    raise exception 'You already belong to this league.';
  end if;
  select * into v_profile from public.profiles where user_id = p_user_id;
  if v_profile.user_id is null or not v_profile.onboarding_completed then
    raise exception 'Confirm your profile before joining a league.';
  end if;
  insert into public.fantasy_teams (league_id, manager_name, team_name)
  values (p_league_id, v_profile.display_name,
    left(split_part(v_profile.display_name, ' ', 1), 72) || '''s Team') returning id into v_team_id;
  insert into public.league_members
    (league_id, user_id, fantasy_team_id, role, first_name, last_name)
  values (p_league_id, p_user_id, v_team_id, 'member',
    split_part(v_profile.display_name, ' ', 1),
    nullif(trim(substr(v_profile.display_name, char_length(split_part(v_profile.display_name, ' ', 1)) + 1)), ''));
  return v_team_id;
end;
$$;


ALTER FUNCTION "public"."join_league_from_invite"("p_league_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_league_with_code"("p_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[[:space:]-]', '', 'g'));
  v_league_id uuid;
  v_league_name text;
begin
  if auth.uid() is null then raise exception 'Sign in to join a league.'; end if;
  -- Serialise attempts for this account, including simultaneous requests.
  perform 1 from public.profiles where user_id = auth.uid() for update;
  if (select count(*) from public.league_invite_code_attempts
      where user_id = auth.uid() and attempted_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('status', 'rate_limited');
  end if;
  insert into public.league_invite_code_attempts (user_id) values (auth.uid());
  if v_code !~ '^[A-HJ-NP-Z2-9]{6}$' then
    return jsonb_build_object('status', 'invalid');
  end if;
  select league.id, league.name into v_league_id, v_league_name
  from public.league_invite_links link
  join public.leagues league on league.id = link.league_id
  where link.code_hash = md5(v_code)
    and link.revoked_at is null and link.expires_at > now()
    and league.status = 'setup';
  if v_league_id is null then return jsonb_build_object('status', 'invalid'); end if;
  perform public.join_league_from_invite(v_league_id, auth.uid());
  return jsonb_build_object('status', 'joined', 'league_id', v_league_id,
                            'league_name', v_league_name);
end;
$_$;


ALTER FUNCTION "public"."join_league_with_code"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."join_league_with_link"("p_token" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to join this league.'; end if;
  select preview.league_id into v_league_id
  from public.preview_league_invite_link(p_token) preview;
  if v_league_id is null then raise exception 'Invite link is invalid or expired.'; end if;
  perform public.join_league_from_invite(v_league_id, auth.uid());
  return v_league_id;
end;
$$;


ALTER FUNCTION "public"."join_league_with_link"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."keep_eliminated_partnership_inactive"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1 from public.cast_members star, public.cast_members pro
    where star.id = new.star_id and pro.id = new.pro_id
      and (star.role in ('Eliminated Star', 'Eliminated Pro')
        or pro.role in ('Eliminated Star', 'Eliminated Pro'))
  ) then
    new.active := false;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."keep_eliminated_partnership_inactive"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_bonus_draft_limit"("p_league_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select greatest(0, league.roster_size
    - public.league_category_limit(league.id, 'Pro')
    - public.league_category_limit(league.id, 'Star')
    - public.league_flex_allowance(league.id))
  from public.leagues league where league.id = p_league_id;
$$;


ALTER FUNCTION "public"."league_bonus_draft_limit"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_cast_category"("p_role" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select case when p_role in ('Pro', 'Star') then p_role else 'Bonus' end;
$$;


ALTER FUNCTION "public"."league_cast_category"("p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_category_limit"("p_league_id" "uuid", "p_role" "text") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select case when p_role in ('Pro', 'Star') then
    (select count(*)::integer from public.cast_members where role = p_role)
    / greatest(1, (select count(*)::integer from public.league_members
      where league_id = p_league_id and status = 'active'))
  else null end;
$$;


ALTER FUNCTION "public"."league_category_limit"("p_league_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_draft_airing_lock_start"("p_at" timestamp with time zone DEFAULT "clock_timestamp"()) RETURNS timestamp with time zone
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select min(((airing.day + airing.starts) at time zone 'America/New_York') - interval '15 minutes')
  from public.weeks w
  cross join lateral (values
    (w.air_date, w.air_start_time),
    (w.second_air_date, coalesce(w.second_air_start_time, w.air_start_time))
  ) as airing(day, starts)
  where not w.is_complete and airing.day is not null
    and p_at >= ((airing.day + airing.starts) at time zone 'America/New_York') - interval '15 minutes';
$$;


ALTER FUNCTION "public"."league_draft_airing_lock_start"("p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_flex_allowance"("p_league_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select case when league.status in ('setup', 'drafting')
    and league.roster_size > public.league_category_limit(league.id, 'Pro')
      + public.league_category_limit(league.id, 'Star')
      + (select count(*)::integer from public.cast_members
         where role not in ('Pro', 'Star')) /
        greatest(1, (select count(*)::integer from public.league_members
          where league_id = league.id and status = 'active'))
    then 1 else 0 end
  from public.leagues league where league.id = p_league_id;
$$;


ALTER FUNCTION "public"."league_flex_allowance"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_pick_is_eligible"("p_league_id" "uuid", "p_team_id" "uuid", "p_cast_member_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_role text; v_team_role integer; v_team_active integer; v_team_bonus integer;
  v_limit integer; v_flex integer;
begin
  select role into v_role from public.cast_members where id = p_cast_member_id;
  if v_role is null then return false; end if;
  if v_role not in ('Pro', 'Star') then
    select count(*) into v_team_bonus from public.league_roster_assignments a
      join public.cast_members c on c.id = a.cast_member_id
      where a.league_id = p_league_id and a.fantasy_team_id = p_team_id
        and c.role not in ('Pro', 'Star');
    return v_team_bonus < public.league_bonus_draft_limit(p_league_id);
  end if;
  select count(*) filter (where c.role = v_role),
    count(*) filter (where c.role in ('Pro', 'Star'))
    into v_team_role, v_team_active
  from public.league_roster_assignments a
  join public.cast_members c on c.id = a.cast_member_id
  where a.league_id = p_league_id and a.fantasy_team_id = p_team_id;
  v_limit := public.league_category_limit(p_league_id, v_role);
  v_flex := public.league_flex_allowance(p_league_id);
  return v_team_role < v_limit + v_flex
    and v_team_active < public.league_category_limit(p_league_id, 'Pro')
      + public.league_category_limit(p_league_id, 'Star') + v_flex
    and (v_team_role < v_limit
      or public.league_unreserved_active_role_count(p_league_id, v_role) > 0);
end;
$$;


ALTER FUNCTION "public"."league_pick_is_eligible"("p_league_id" "uuid", "p_team_id" "uuid", "p_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_trade_airing_locked"("p_at" timestamp with time zone DEFAULT "clock_timestamp"()) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."league_trade_airing_locked"("p_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."league_unreserved_active_role_count"("p_league_id" "uuid", "p_role" "text") RETURNS integer
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select (select count(*)::integer from public.cast_members where role = p_role)
    - (select count(*)::integer from public.league_roster_assignments a
       join public.cast_members c on c.id = a.cast_member_id
       where a.league_id = p_league_id and c.role = p_role)
    - coalesce((select sum(greatest(0,
        public.league_category_limit(p_league_id, p_role) -
        (select count(*)::integer from public.league_roster_assignments a
         join public.cast_members c on c.id = a.cast_member_id
         where a.league_id = p_league_id and a.fantasy_team_id = member.fantasy_team_id
           and c.role = p_role)))::integer
      from public.league_members member
      where member.league_id = p_league_id and member.status = 'active'), 0);
$$;


ALTER FUNCTION "public"."league_unreserved_active_role_count"("p_league_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_league_members"("p_league_id" "uuid") RETURNS TABLE("user_id" "uuid", "username" "text", "display_name" "text", "avatar_url" "text", "member_role" "text", "fantasy_team_id" "uuid", "team_name" "text", "joined_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.can_read_league(p_league_id) then raise exception 'League access required.'; end if;
  return query select member.user_id, profile.username, profile.display_name,
    profile.avatar_url, member.role, member.fantasy_team_id, team.team_name,
    member.joined_at
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  left join public.fantasy_teams team on team.id = member.fantasy_team_id
  where member.league_id = p_league_id and member.status = 'active'
  order by member.role desc, member.joined_at, profile.username;
end;
$$;


ALTER FUNCTION "public"."list_league_members"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mirror_default_league_trade_history"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.league_id = public.default_fantasy_league_id() then
    -- A later deleted team may clear the nullable legacy FK. Keep the already
    -- copied event's historical team IDs instead of blocking that deletion.
    if new.initiator_team_id is null or new.counterparty_team_id is null then
      return new;
    end if;
    insert into public.league_trade_events
      (id, league_id, trade_id, event_type, initiator_team_id,
       counterparty_team_id, initiator_cast_member_name,
       counterparty_cast_member_name, notification_team_id,
       dismissed_at, event_at)
    values
      (new.id, new.league_id, new.trade_id, new.event_type,
       new.initiator_team_id, new.counterparty_team_id,
       new.initiator_cast_member_name, new.counterparty_cast_member_name,
       new.notification_team_id, new.dismissed_at, new.event_at)
    on conflict (id) do update set
      league_id = excluded.league_id,
      trade_id = excluded.trade_id,
      event_type = excluded.event_type,
      initiator_team_id = excluded.initiator_team_id,
      counterparty_team_id = excluded.counterparty_team_id,
      initiator_cast_member_name = excluded.initiator_cast_member_name,
      counterparty_cast_member_name = excluded.counterparty_cast_member_name,
      notification_team_id = excluded.notification_team_id,
      dismissed_at = excluded.dismissed_at,
      event_at = excluded.event_at;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."mirror_default_league_trade_history"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mirror_default_league_week_snapshot"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.league_id = public.default_fantasy_league_id() then
    insert into public.league_weekly_roster_snapshots
      (league_id, week_id, cast_member_id, fantasy_team_id,
       cast_member_name, cast_role, appearance_points, manager_name, team_name, created_at)
    values
      (new.league_id, new.week_id, new.cast_member_id, new.fantasy_team_id,
       new.cast_member_name, new.cast_role, new.appearance_points,
       new.manager_name, new.team_name, new.created_at)
    on conflict (league_id, week_id, cast_member_id) do update set
      fantasy_team_id = excluded.fantasy_team_id,
      cast_member_name = excluded.cast_member_name,
      cast_role = excluded.cast_role,
      appearance_points = excluded.appearance_points,
      manager_name = excluded.manager_name,
      team_name = excluded.team_name,
      created_at = excluded.created_at;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."mirror_default_league_week_snapshot"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_profile_username"("p_seed" "text", "p_user_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_base text := public.profile_username_base(p_seed, p_user_id);
  v_candidate text := v_base;
  v_suffix integer := 1;
  v_suffix_text text;
begin
  while exists (select 1 from public.profiles where lower(username) = lower(v_candidate)) loop
    v_suffix := v_suffix + 1;
    v_suffix_text := v_suffix::text;
    v_candidate := left(v_base, 20 - char_length(v_suffix_text)) || v_suffix_text;
  end loop;
  return v_candidate;
end;
$$;


ALTER FUNCTION "public"."next_profile_username"("p_seed" "text", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_competing_pair_appearance"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if exists (
    select 1 from public.dances as d
    join public.partnerships as pair on pair.id = d.partnership_id
    where d.id = new.dance_id and d.kind = 'competitive'
      and new.cast_member_id in (pair.star_id, pair.pro_id)
  ) then
    raise exception 'The competing couple cannot be added as a cast appearance.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."prevent_competing_pair_appearance"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_completed_week_edit"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare v_week_id uuid;
begin
  if tg_table_name = 'dances' then
    if tg_op = 'DELETE' then v_week_id := old.week_id; else v_week_id := new.week_id; end if;
  else
    select week_id into v_week_id from public.dances
    where id = case when tg_op = 'DELETE' then old.dance_id else new.dance_id end;
  end if;
  if exists (select 1 from public.weeks where id = v_week_id and is_complete) then
    raise exception 'This week is complete and its scoring is read-only.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."prevent_completed_week_edit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_completed_week_metadata_edit"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if old.is_complete and new is distinct from old then
    raise exception 'This week is complete and its setup is read-only.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."prevent_completed_week_metadata_edit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preview_league_invite_link"("p_token" "text") RETURNS TABLE("league_id" "uuid", "league_name" "text", "expires_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select league.id, league.name, link.expires_at
  from public.league_invite_links link
  join public.leagues league on league.id = link.league_id
  where char_length(coalesce(p_token, '')) = 64
    and link.token_hash = md5(p_token)
    and link.revoked_at is null and link.expires_at > now()
    and league.status = 'setup';
$$;


ALTER FUNCTION "public"."preview_league_invite_link"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_expired_league_drafts"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league_id uuid;
begin
  for v_league_id in select id from public.leagues
    where status = 'drafting' and not draft_timer_disabled
  loop
    perform public.advance_league_draft_clock(v_league_id);
  end loop;
end;
$$;


ALTER FUNCTION "public"."process_expired_league_drafts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profile_display_name_from_auth"("p_user" "auth"."users") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select left(coalesce(
    nullif(trim(p_user.raw_user_meta_data ->> 'display_name'), ''),
    nullif(trim(p_user.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(p_user.raw_user_meta_data ->> 'name'), ''),
    nullif(trim(concat_ws(' ', p_user.raw_user_meta_data ->> 'first_name', p_user.raw_user_meta_data ->> 'last_name')), ''),
    nullif(split_part(coalesce(p_user.email, ''), '@', 1), ''),
    'User'
  ), 80);
$$;


ALTER FUNCTION "public"."profile_display_name_from_auth"("p_user" "auth"."users") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profile_username_base"("p_seed" "text", "p_user_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  v_base text;
begin
  v_base := regexp_replace(lower(coalesce(p_seed, '')), '[^a-z0-9_]+', '', 'g');
  v_base := left(v_base, 20);
  if char_length(v_base) < 3 then
    v_base := left(v_base || replace(p_user_id::text, '-', ''), 20);
  end if;
  if char_length(v_base) < 3 then v_base := rpad(v_base, 3, '_'); end if;
  return v_base;
end;
$$;


ALTER FUNCTION "public"."profile_username_base"("p_seed" "text", "p_user_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_trade_offers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "initiator_team_id" "uuid" NOT NULL,
    "counterparty_team_id" "uuid" NOT NULL,
    "initiator_cast_member_id" "uuid" NOT NULL,
    "counterparty_cast_member_id" "uuid" NOT NULL,
    "awaiting_team_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '48:00:00'::interval) NOT NULL,
    CONSTRAINT "league_trade_offers_check" CHECK (("initiator_team_id" <> "counterparty_team_id")),
    CONSTRAINT "league_trade_offers_check1" CHECK (("initiator_cast_member_id" <> "counterparty_cast_member_id")),
    CONSTRAINT "league_trade_offers_check2" CHECK ((("awaiting_team_id" = "initiator_team_id") OR ("awaiting_team_id" = "counterparty_team_id"))),
    CONSTRAINT "league_trade_offers_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'countered'::"text"])))
);


ALTER TABLE "public"."league_trade_offers" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_league_trade_event"("p_offer" "public"."league_trade_offers", "p_event_type" "text", "p_notify_team_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  insert into public.league_trade_events
    (league_id, trade_id, event_type, initiator_team_id, counterparty_team_id,
     initiator_cast_member_name, counterparty_cast_member_name, notification_team_id)
  values (p_offer.league_id, p_offer.id, p_event_type,
    p_offer.initiator_team_id, p_offer.counterparty_team_id,
    coalesce((select name from public.cast_members where id = p_offer.initiator_cast_member_id), 'Former cast member'),
    coalesce((select name from public.cast_members where id = p_offer.counterparty_cast_member_id), 'Former cast member'),
    p_notify_team_id);
end;
$$;


ALTER FUNCTION "public"."record_league_trade_event"("p_offer" "public"."league_trade_offers", "p_event_type" "text", "p_notify_team_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_trade_history_event"("p_trade" "public"."trade_offers", "p_event_type" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_initiator_team_name text;
  v_counterparty_team_name text;
  v_initiator_cast_name text;
  v_counterparty_cast_name text;
  v_notification_team_id uuid;
begin
  if p_event_type not in ('countered', 'accepted', 'denied', 'expired', 'cancelled', 'invalidated') then
    raise exception 'Invalid trade history event.';
  end if;

  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_initiator_team_name from public.fantasy_teams where id = p_trade.initiator_team_id;
  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_counterparty_team_name from public.fantasy_teams where id = p_trade.counterparty_team_id;
  select name into v_initiator_cast_name from public.cast_members where id = p_trade.initiator_cast_member_id;
  select name into v_counterparty_cast_name from public.cast_members where id = p_trade.counterparty_cast_member_id;

  -- For an accepted or denied offer, notify whichever team sent the exact
  -- offer being answered. This also works after a counter reverses who is
  -- awaiting the response.
  if p_event_type in ('accepted', 'denied') then
    v_notification_team_id := case
      when p_trade.awaiting_team_id = p_trade.initiator_team_id then p_trade.counterparty_team_id
      else p_trade.initiator_team_id
    end;
  end if;

  insert into public.trade_history (
    trade_id, event_type,
    initiator_team_id, counterparty_team_id,
    initiator_team_name, counterparty_team_name,
    initiator_cast_member_id, counterparty_cast_member_id,
    initiator_cast_member_name, counterparty_cast_member_name,
    notification_team_id
  ) values (
    p_trade.id, p_event_type,
    p_trade.initiator_team_id, p_trade.counterparty_team_id,
    coalesce(v_initiator_team_name, 'Former team'), coalesce(v_counterparty_team_name, 'Former team'),
    p_trade.initiator_cast_member_id, p_trade.counterparty_cast_member_id,
    coalesce(v_initiator_cast_name, 'Former cast member'), coalesce(v_counterparty_cast_name, 'Former cast member'),
    v_notification_team_id
  );
end;
$$;


ALTER FUNCTION "public"."record_trade_history_event"("p_trade" "public"."trade_offers", "p_event_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_automatic_roster_size"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league_id uuid;
begin
  v_league_id := case when tg_op = 'DELETE' then old.league_id else new.league_id end;
  if v_league_id <> public.default_fantasy_league_id() then
    update public.leagues league
    set roster_size = public.suggest_league_roster_size(
          (select count(*)::integer from public.league_members member
           where member.league_id = v_league_id and member.status = 'active')),
        updated_at = now()
    where league.id = v_league_id and league.status = 'setup'
      and not league.roster_size_overridden;
  end if;
  return null;
end;
$$;


ALTER FUNCTION "public"."refresh_automatic_roster_size"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_my_league_snapshots"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.is_league_member(p_league_id) then raise exception 'League membership required.'; end if;
  perform public.capture_due_secondary_league_snapshots(p_league_id);
end;
$$;


ALTER FUNCTION "public"."refresh_my_league_snapshots"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."regenerate_league_invite_link"("p_league_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_token text;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are available before the draft starts.';
  end if;
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.league_invite_links (league_id, token_hash, created_by)
  values (p_league_id, md5(v_token), auth.uid());
  return v_token;
end;
$$;


ALTER FUNCTION "public"."regenerate_league_invite_link"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_cast_member_from_team"("p_cast_member_id" "uuid", "p_team_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  update public.cast_members set fantasy_team_id = null where id = p_cast_member_id and fantasy_team_id = p_team_id;
  if not found then raise exception 'That cast member is not assigned to this team.'; end if;
end;
$$;


ALTER FUNCTION "public"."remove_cast_member_from_team"("p_cast_member_id" "uuid", "p_team_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_league_member"("p_league_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_team_id uuid;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Members can only be removed before the draft starts.';
  end if;
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = p_user_id and role = 'member';
  if v_team_id is null then raise exception 'Member not found.'; end if;
  delete from public.league_members where league_id = p_league_id and user_id = p_user_id;
  delete from public.fantasy_teams where id = v_team_id and league_id = p_league_id;
end;
$$;


ALTER FUNCTION "public"."remove_league_member"("p_league_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_league_trade"("p_league_id" "uuid", "p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_team_id uuid; v_other_team_id uuid; v_id uuid;
begin
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null or (select status from public.leagues where id = p_league_id) <> 'active' then
    raise exception 'Trading is available after your league draft is complete.';
  end if;
  perform 1 from public.leagues where id = p_league_id for update;
  perform public.expire_league_trade_offers(p_league_id);
  if p_my_cast_member_id = p_requested_cast_member_id then raise exception 'Choose different cast members.'; end if;
  if not exists (select 1 from public.league_roster_assignments where league_id = p_league_id
    and cast_member_id = p_my_cast_member_id and fantasy_team_id = v_team_id) then
    raise exception 'Offered cast member is no longer on your team.';
  end if;
  select fantasy_team_id into v_other_team_id from public.league_roster_assignments
  where league_id = p_league_id and cast_member_id = p_requested_cast_member_id;
  if v_other_team_id is null or v_other_team_id = v_team_id then
    raise exception 'Choose a cast member from another team.';
  end if;
  if exists (select 1 from public.league_trade_offers offer where offer.league_id = p_league_id
    and (p_my_cast_member_id in (offer.initiator_cast_member_id, offer.counterparty_cast_member_id)
      or p_requested_cast_member_id in (offer.initiator_cast_member_id, offer.counterparty_cast_member_id))) then
    raise exception 'One of these cast members has an active offer.';
  end if;
  insert into public.league_trade_offers
    (league_id, initiator_team_id, counterparty_team_id,
     initiator_cast_member_id, counterparty_cast_member_id, awaiting_team_id)
  values (p_league_id, v_team_id, v_other_team_id,
    p_my_cast_member_id, p_requested_cast_member_id, v_other_team_id)
  returning id into v_id;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."request_league_trade"("p_league_id" "uuid", "p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_trade"("p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_my_team_id uuid;
  v_other_team_id uuid;
  v_trade_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  if p_my_cast_member_id = p_requested_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform 1 from public.cast_members where id in (p_my_cast_member_id, p_requested_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = p_my_cast_member_id) is distinct from v_my_team_id then
    raise exception 'The cast member you are offering is no longer on your team.';
  end if;
  select fantasy_team_id into v_other_team_id from public.cast_members where id = p_requested_cast_member_id;
  if v_other_team_id is null or v_other_team_id = v_my_team_id then
    raise exception 'Choose a cast member from another fantasy team.';
  end if;
  if exists (
    select 1 from public.trade_offers
    where p_my_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
       or p_requested_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
  ) then
    raise exception 'One of these cast members is already part of an active trade offer.';
  end if;

  insert into public.trade_offers (
    initiator_team_id, counterparty_team_id,
    initiator_cast_member_id, counterparty_cast_member_id,
    status, awaiting_team_id, expires_at
  ) values (
    v_my_team_id, v_other_team_id,
    p_my_cast_member_id, p_requested_cast_member_id,
    'pending', v_other_team_id, now() + interval '48 hours'
  ) returning id into v_trade_id;
  return v_trade_id;
end;
$$;


ALTER FUNCTION "public"."request_trade"("p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."respond_to_league_invite"("p_invite_id" "uuid", "p_accept" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_invite public.league_invites; v_team_id uuid;
begin
  select * into v_invite from public.league_invites where id = p_invite_id for update;
  if v_invite.id is null or v_invite.invitee_id is distinct from auth.uid()
     or v_invite.status <> 'pending' or v_invite.expires_at <= now() then
    raise exception 'Invitation is no longer available.';
  end if;
  if p_accept then v_team_id := public.join_league_from_invite(v_invite.league_id, auth.uid()); end if;
  update public.league_invites set status = case when p_accept then 'accepted' else 'declined' end,
    responded_at = now() where id = p_invite_id;
  return v_team_id;
end;
$$;


ALTER FUNCTION "public"."respond_to_league_invite"("p_invite_id" "uuid", "p_accept" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."respond_to_league_trade"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text" DEFAULT NULL::"text", "p_replacement_cast_member_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_offer public.league_trade_offers; v_is_default boolean := false;
begin
  select * into v_offer from public.league_trade_offers where id = p_offer_id;
  if v_offer.league_id = public.default_fantasy_league_id() then
    v_is_default := true;
    perform 1 from public.leagues where id = v_offer.league_id for update;
    select * into v_offer from public.league_trade_offers
    where id = p_offer_id for update;
    if v_offer.id is null then raise exception 'Trade offer is no longer available.'; end if;
    if not (select shared_workspace_enabled from public.leagues where id = v_offer.league_id) then
      raise exception 'This league has not switched to the updated trade center yet.';
    end if;
    if p_action in ('accept', 'counter') and public.league_trade_airing_locked() then
      raise exception 'Trades are paused from two hours before the airing until two hours after.';
    end if;
  end if;

  perform public.respond_to_league_trade_without_default(
    p_offer_id, p_action, p_replace_side, p_replacement_cast_member_id);

  if v_is_default and p_action = 'accept' then
    update public.cast_members cast_member
    set fantasy_team_id = case
      when cast_member.id = v_offer.initiator_cast_member_id then v_offer.counterparty_team_id
      else v_offer.initiator_team_id end
    where cast_member.id in
      (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id);
    if exists (
      select 1 from public.cast_members cast_member
      left join public.league_roster_assignments assignment
        on assignment.league_id = v_offer.league_id
          and assignment.cast_member_id = cast_member.id
      where cast_member.id in
        (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id)
        and cast_member.fantasy_team_id is distinct from assignment.fantasy_team_id
    ) then
      raise exception 'The trade roster could not be synchronized.';
    end if;
  end if;
end;
$$;


ALTER FUNCTION "public"."respond_to_league_trade"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text", "p_replacement_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."respond_to_league_trade_without_default"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text" DEFAULT NULL::"text", "p_replacement_cast_member_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_offer public.league_trade_offers; v_other_offer public.league_trade_offers;
  v_my_team_id uuid; v_sender_team_id uuid;
  v_replacement_team_id uuid; v_expected_team_id uuid;
  v_accepted_league_id uuid; v_accepted_initiator_cast_id uuid;
  v_accepted_counterparty_cast_id uuid;
begin
  select * into v_offer from public.league_trade_offers where id = p_offer_id;
  if v_offer.id is null then raise exception 'Trade offer is no longer available.'; end if;
  perform 1 from public.leagues where id = v_offer.league_id for update;
  perform public.expire_league_trade_offers(v_offer.league_id);
  select * into v_offer from public.league_trade_offers where id = p_offer_id for update;
  if v_offer.id is null then raise exception 'Trade offer has expired.'; end if;
  select fantasy_team_id into v_my_team_id from public.league_members
  where league_id = v_offer.league_id and user_id = auth.uid() and status = 'active';
  if v_my_team_id is null then raise exception 'League membership required.'; end if;
  v_sender_team_id := case when v_offer.awaiting_team_id = v_offer.initiator_team_id
    then v_offer.counterparty_team_id else v_offer.initiator_team_id end;

  if p_action = 'cancel' then
    if v_my_team_id <> v_sender_team_id then raise exception 'Only the sender can cancel this offer.'; end if;
    perform public.record_league_trade_event(v_offer, 'cancelled');
    delete from public.league_trade_offers where id = p_offer_id;
    return;
  end if;
  if v_my_team_id <> v_offer.awaiting_team_id then raise exception 'This offer is awaiting the other manager.'; end if;
  if p_action = 'deny' then
    perform public.record_league_trade_event(v_offer, 'denied', v_sender_team_id);
    delete from public.league_trade_offers where id = p_offer_id;
  elsif p_action = 'accept' then
    if not exists (select 1 from public.league_roster_assignments where league_id = v_offer.league_id
      and cast_member_id = v_offer.initiator_cast_member_id and fantasy_team_id = v_offer.initiator_team_id)
      or not exists (select 1 from public.league_roster_assignments where league_id = v_offer.league_id
      and cast_member_id = v_offer.counterparty_cast_member_id and fantasy_team_id = v_offer.counterparty_team_id) then
      raise exception 'The offer no longer matches the current rosters.';
    end if;
    update public.league_roster_assignments
    set fantasy_team_id = case
      when cast_member_id = v_offer.initiator_cast_member_id then v_offer.counterparty_team_id
      else v_offer.initiator_team_id end
    where league_id = v_offer.league_id
      and cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id);
    perform public.record_league_trade_event(v_offer, 'accepted', v_sender_team_id);
    v_accepted_league_id := v_offer.league_id;
    v_accepted_initiator_cast_id := v_offer.initiator_cast_member_id;
    v_accepted_counterparty_cast_id := v_offer.counterparty_cast_member_id;
    delete from public.league_trade_offers where id = p_offer_id;
    -- Other offers involving either newly traded cast member can no longer be honored.
    for v_other_offer in select * from public.league_trade_offers offer
      where offer.league_id = v_accepted_league_id
        and (offer.initiator_cast_member_id in (v_accepted_initiator_cast_id, v_accepted_counterparty_cast_id)
          or offer.counterparty_cast_member_id in (v_accepted_initiator_cast_id, v_accepted_counterparty_cast_id))
      for update
    loop
      perform public.record_league_trade_event(v_other_offer, 'invalidated');
      delete from public.league_trade_offers where id = v_other_offer.id;
    end loop;
  elsif p_action = 'counter' then
    if p_replace_side not in ('initiator', 'counterparty') or p_replacement_cast_member_id is null then
      raise exception 'Replace exactly one side of the offer.';
    end if;
    v_expected_team_id := case when p_replace_side = 'initiator'
      then v_offer.initiator_team_id else v_offer.counterparty_team_id end;
    select fantasy_team_id into v_replacement_team_id from public.league_roster_assignments
    where league_id = v_offer.league_id and cast_member_id = p_replacement_cast_member_id;
    if v_replacement_team_id is distinct from v_expected_team_id
      or p_replacement_cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id) then
      raise exception 'Choose another cast member on the same team.';
    end if;
    if exists (select 1 from public.league_trade_offers offer
      where offer.league_id = v_offer.league_id and offer.id <> v_offer.id
        and p_replacement_cast_member_id in (offer.initiator_cast_member_id, offer.counterparty_cast_member_id)) then
      raise exception 'That cast member has another active offer.';
    end if;
    perform public.record_league_trade_event(v_offer, 'countered');
    update public.league_trade_offers set
      initiator_cast_member_id = case when p_replace_side = 'initiator'
        then p_replacement_cast_member_id else initiator_cast_member_id end,
      counterparty_cast_member_id = case when p_replace_side = 'counterparty'
        then p_replacement_cast_member_id else counterparty_cast_member_id end,
      awaiting_team_id = v_sender_team_id, status = 'countered',
      expires_at = now() + interval '48 hours', updated_at = now()
    where id = p_offer_id;
  else
    raise exception 'Invalid trade action.';
  end if;
end;
$$;


ALTER FUNCTION "public"."respond_to_league_trade_without_default"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text", "p_replacement_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_league_invite_link"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
end;
$$;


ALTER FUNCTION "public"."revoke_league_invite_link"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rotate_expired_league_invites"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league record; v_count integer := 0;
begin
  for v_league in
    select league.id, league.created_by
    from public.leagues league
    left join public.league_invite_links link
      on link.league_id = league.id and link.revoked_at is null
    where league.status = 'setup'
      and (link.id is null or link.expires_at <= now() or link.code_value is null)
  loop
    perform 1 from public.leagues where id = v_league.id for update;
    if (select status from public.leagues where id = v_league.id) = 'setup'
       and not exists (
         select 1 from public.league_invite_links
         where league_id = v_league.id and revoked_at is null
           and expires_at > now() and code_value is not null
       ) then
      perform public.rotate_league_invite_credentials(v_league.id, v_league.created_by);
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."rotate_expired_league_invites"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rotate_league_invite_credentials"("p_league_id" "uuid", "p_creator" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_token text;
  v_code text;
  v_bytes bytea;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_i integer;
  v_tries integer;
begin
  -- Internal only. Serialise code generation to make the uniqueness check safe.
  perform pg_advisory_xact_lock(hashtext('mirrorball-invite-code-generation'));
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  for v_tries in 1..10 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for v_i in 0..5 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, v_i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.league_invite_links where code_hash = md5(v_code));
  end loop;
  if exists (select 1 from public.league_invite_links where code_hash = md5(v_code)) then
    raise exception 'Could not generate a unique invite code. Please try again.';
  end if;
  insert into public.league_invite_links
    (league_id, token_hash, code_hash, token_value, code_value, created_by, expires_at)
  values (p_league_id, md5(v_token), md5(v_code), v_token, v_code, p_creator,
          now() + interval '48 hours');
end;
$$;


ALTER FUNCTION "public"."rotate_league_invite_credentials"("p_league_id" "uuid", "p_creator" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_cast_member_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_member_id uuid;
  v_pair_role text;
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'A cast member name is required.'; end if;
  if p_role not in ('Star','Pro','Eliminated Star','Eliminated Pro','Troupe','DWTS Next Pro','Judges + Hosts','Surprise') then raise exception 'Choose a valid cast role.'; end if;
  if p_image_position is null or p_image_position < 0 or p_image_position > 100 then raise exception 'Portrait position must be from 0 to 100.'; end if;
  if p_role = 'Surprise' and (p_custom_appearance_points is null or p_custom_appearance_points < 0) then raise exception 'Set a non-negative Surprise appearance rate.'; end if;
  if p_role = 'Judges + Hosts' and p_role_detail not in ('Judge','Host','Judge + Host') then raise exception 'Choose Judge, Host, or Judge + Host.'; end if;

  if p_cast_member_id is null then
    insert into public.cast_members (name,role,image_path,image_position,custom_appearance_points,role_detail,is_hough)
    values (trim(p_name),p_role,p_image_path,p_image_position,case when p_role='Surprise' then p_custom_appearance_points else null end,
      case when p_role='Judges + Hosts' then p_role_detail else null end,
      p_role='Judges + Hosts' and coalesce(p_is_hough,false)) returning id into v_member_id;
  else
    update public.cast_members set name=trim(p_name), role=p_role, image_path=p_image_path, image_position=p_image_position,
      custom_appearance_points=case when p_role='Surprise' then p_custom_appearance_points else null end,
      role_detail=case when p_role='Judges + Hosts' then p_role_detail else null end,
      is_hough=p_role='Judges + Hosts' and coalesce(p_is_hough,false)
    where id=p_cast_member_id returning id into v_member_id;
    if v_member_id is null then raise exception 'Cast member not found.'; end if;
  end if;

  v_pair_role := case when p_role in ('Star','Eliminated Star') then 'Star' when p_role in ('Pro','Eliminated Pro') then 'Pro' else 'Star' end;
  perform public.set_cast_partnership_atomic(v_member_id, v_pair_role,
    case when p_role in ('Star','Pro','Eliminated Star','Eliminated Pro') then p_partner_id else null end,
    case when p_role in ('Star','Pro','Eliminated Star','Eliminated Pro') then p_partnership_name else null end);
  return v_member_id;
end;
$$;


ALTER FUNCTION "public"."save_cast_member_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_cast_member_profile_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare v_member_id uuid; v_wins_eligible boolean;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if p_mirrorball_wins is null or p_mirrorball_wins < 0 or p_mirrorball_wins > 99 then raise exception 'Past wins must be from 0 to 99.'; end if;
  v_wins_eligible := p_role in ('Pro','Eliminated Pro') or (p_role = 'Judges + Hosts' and coalesce(p_is_hough, false));
  if p_mirrorball_wins <> 0 and not v_wins_eligible then
    raise exception 'Past Mirrorball wins are available only for pros and Hough judges or hosts.';
  end if;
  v_member_id := public.save_cast_member_atomic(p_cast_member_id, p_name, p_role, p_image_path, p_image_position,
    p_custom_appearance_points, p_role_detail, p_is_hough, p_partner_id, p_partnership_name);
  update public.cast_members set bio = nullif(trim(p_bio), ''), career_highlights = nullif(trim(p_career_highlights), ''),
    mirrorball_wins = case when v_wins_eligible then p_mirrorball_wins else 0 end
  where id = v_member_id;
  return v_member_id;
end;
$$;


ALTER FUNCTION "public"."save_cast_member_profile_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_cast_member_profile_with_surprise_role"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer, "p_surprise_base_role" "text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare v_member_id uuid;
begin
  if p_role = 'Surprise' and (p_surprise_base_role is null or p_surprise_base_role not in
    ('Eliminated Pro', 'Eliminated Star', 'Troupe', 'DWTS Next Pro', 'Judges + Hosts')) then
    raise exception 'Choose the normal role for this surprise cast member.';
  end if;
  v_member_id := public.save_cast_member_profile_atomic(
    p_cast_member_id, p_name, p_role, p_image_path, p_image_position,
    p_custom_appearance_points, p_role_detail, p_is_hough, p_partner_id,
    p_partnership_name, p_bio, p_career_highlights, p_mirrorball_wins);
  update public.cast_members set surprise_base_role =
    case when p_role = 'Surprise' then p_surprise_base_role else null end
  where id = v_member_id;
  return v_member_id;
end;
$$;


ALTER FUNCTION "public"."save_cast_member_profile_with_surprise_role"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer, "p_surprise_base_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_dance_atomic"("p_week_id" "uuid", "p_dance_id" "uuid", "p_kind" "text", "p_partnership_id" "uuid", "p_name" "text", "p_dance_type" "text", "p_song" "text", "p_judge_scores" "jsonb", "p_cast_member_ids" "uuid"[], "p_scores_only" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $_$
declare
  v_week public.weeks%rowtype; v_dance public.dances%rowtype; v_dance_id uuid;
  v_score jsonb; v_judge_name text; v_expected_judges text[];
  v_cast_ids uuid[] := coalesce(p_cast_member_ids, '{}'::uuid[]);
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if p_dance_id is not null then
    select * into v_dance from public.dances where id = p_dance_id and week_id = p_week_id for update;
    if not found then raise exception 'Dance not found in this week.'; end if;
  end if;
  if v_week.is_complete and not (
    (coalesce(p_scores_only, false) and p_dance_id is not null) or
    (p_dance_id is null and p_kind = 'performance' and not coalesce(p_scores_only, false))
  ) then raise exception 'Use the Week Ledger to correct a completed week.'; end if;
  if p_scores_only and (p_dance_id is null or v_dance.kind <> 'competitive') then raise exception 'Only an existing competitive dance supports score-only edits.'; end if;
  if p_scores_only then p_kind := v_dance.kind; end if;
  if p_kind is null or p_kind not in ('competitive','performance') then raise exception 'Choose a valid dance type.'; end if;
  if p_kind = 'competitive' and (case when p_scores_only then v_dance.partnership_id else p_partnership_id end) is null then raise exception 'A competitive dance needs a couple.'; end if;
  if p_kind = 'performance' and p_partnership_id is not null then raise exception 'A performance cannot have a competing couple.'; end if;
  if jsonb_typeof(p_judge_scores) is distinct from 'array' then raise exception 'Judge scores must be a list.'; end if;
  if p_kind = 'performance' and jsonb_array_length(p_judge_scores) > 0 then raise exception 'A performance cannot have judge scores.'; end if;
  if (select count(*) from unnest(v_cast_ids) m(member_id)) <> (select count(distinct member_id) from unnest(v_cast_ids) m(member_id)) then raise exception 'A cast member can appear only once in a dance.'; end if;
  v_expected_judges := array['Carrie Ann','Derek','Bruno']::text[];
  if nullif(trim(v_week.guest_judge_name), '') is not null then v_expected_judges := array_append(v_expected_judges, v_week.guest_judge_name); end if;
  for v_score in select item from jsonb_array_elements(p_judge_scores) scores(item) loop
    v_judge_name := v_score->>'judge_name';
    if v_judge_name is null or not (v_judge_name = any(v_expected_judges)) then raise exception 'Unrecognized judge: %.', coalesce(v_judge_name, '(blank)'); end if;
    if coalesce(v_score->>'score', '') !~ '^(10|[0-9])$' then raise exception 'Each judge score must be a whole number from 0 to 10.'; end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_judge_scores)) <> (select count(distinct item->>'judge_name') from jsonb_array_elements(p_judge_scores) scores(item)) then raise exception 'Each judge can score a dance only once.'; end if;
  if p_dance_id is null then
    insert into public.dances (week_id,kind,partnership_id,name,dance_type,song,sort_order)
    values (p_week_id,p_kind,p_partnership_id,nullif(trim(p_name),''),nullif(trim(p_dance_type),''),nullif(trim(p_song),''),coalesce((select max(sort_order)+1 from public.dances where week_id=p_week_id),1))
    returning id into v_dance_id;
  else
    v_dance_id := p_dance_id;
    if not p_scores_only then update public.dances set kind=p_kind, partnership_id=p_partnership_id, name=nullif(trim(p_name),''), dance_type=nullif(trim(p_dance_type),''), song=nullif(trim(p_song),'') where id=v_dance_id; end if;
  end if;
  delete from public.dance_judge_scores where dance_id=v_dance_id;
  insert into public.dance_judge_scores (dance_id,judge_name,score)
  select v_dance_id,item->>'judge_name',(item->>'score')::integer from jsonb_array_elements(p_judge_scores) scores(item);
  if not p_scores_only then
    delete from public.dance_appearances where dance_id=v_dance_id;
    insert into public.dance_appearances (dance_id,cast_member_id) select v_dance_id,member_id from unnest(v_cast_ids) m(member_id);
  end if;
  return v_dance_id;
end;
$_$;


ALTER FUNCTION "public"."save_dance_atomic"("p_week_id" "uuid", "p_dance_id" "uuid", "p_kind" "text", "p_partnership_id" "uuid", "p_name" "text", "p_dance_type" "text", "p_song" "text", "p_judge_scores" "jsonb", "p_cast_member_ids" "uuid"[], "p_scores_only" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_new_role_for_leagues"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  insert into public.league_role_rates (league_id, role_id, appearance_points)
  select league.id, new.id, new.appearance_points from public.leagues league
  on conflict (league_id, role_id) do nothing;
  return new;
end;
$$;


ALTER FUNCTION "public"."seed_new_role_for_leagues"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_cast_partnership_atomic"("p_cast_member_id" "uuid", "p_role" "text", "p_partner_id" "uuid", "p_partnership_name" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_pair_id uuid;
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if p_role not in ('Star', 'Pro') then raise exception 'A partnership member must be a star or pro.'; end if;
  perform 1 from public.cast_members where id = p_cast_member_id for update;
  if not found then raise exception 'Cast member not found.'; end if;
  if p_partner_id = p_cast_member_id then raise exception 'A cast member cannot partner with themselves.'; end if;
  if p_partner_id is not null then
    perform 1 from public.cast_members where id = p_partner_id for update;
    if not found then raise exception 'Partner not found.'; end if;
    if p_role = 'Star' and not exists (select 1 from public.cast_members where id=p_partner_id and role in ('Pro','Eliminated Pro')) then raise exception 'A star must be paired with a pro.'; end if;
    if p_role = 'Pro' and not exists (select 1 from public.cast_members where id=p_partner_id and role in ('Star','Eliminated Star')) then raise exception 'A pro must be paired with a star.'; end if;
  end if;

  select id into v_pair_id from public.partnerships
  where p_cast_member_id in (star_id, pro_id) and
    (case when star_id = p_cast_member_id then pro_id else star_id end) is not distinct from p_partner_id;
  if v_pair_id is not null then
    update public.partnerships set partnership_name = nullif(trim(p_partnership_name), ''), active = true where id = v_pair_id;
    return v_pair_id;
  end if;

  delete from public.partnerships where p_cast_member_id in (star_id, pro_id)
    or (p_partner_id is not null and p_partner_id in (star_id, pro_id));
  if p_partner_id is null then return null; end if;

  insert into public.partnerships (star_id, pro_id, active, partnership_name)
  values (
    case when p_role = 'Star' then p_cast_member_id else p_partner_id end,
    case when p_role = 'Pro' then p_cast_member_id else p_partner_id end,
    true,
    nullif(trim(p_partnership_name), '')
  ) returning id into v_pair_id;
  return v_pair_id;
end;
$$;


ALTER FUNCTION "public"."set_cast_partnership_atomic"("p_cast_member_id" "uuid", "p_role" "text", "p_partner_id" "uuid", "p_partnership_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_league_draft_deadline"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.status = 'drafting' and old.status is distinct from 'drafting' then
    new.draft_pick_deadline_at := case when new.draft_timer_disabled then null
      else clock_timestamp() + interval '2 minutes' end;
  elsif new.status <> 'drafting' then
    new.draft_pick_deadline_at := null;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."set_league_draft_deadline"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_league_draft_paused"("p_league_id" "uuid", "p_paused" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league public.leagues; v_remaining integer;
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
  if p_paused and v_league.draft_paused_at is null then
    v_remaining := least(120, greatest(0, coalesce(ceil(extract(epoch from
      v_league.draft_pick_deadline_at - clock_timestamp()))::integer, 120)));
    update public.leagues set
      draft_seconds_remaining = v_remaining,
      draft_pick_deadline_at = null,
      draft_paused_at = clock_timestamp(),
      updated_at = clock_timestamp()
    where id = p_league_id;
  elsif not p_paused and v_league.draft_paused_at is not null then
    update public.leagues set
      draft_pick_deadline_at = clock_timestamp()
        + make_interval(secs => coalesce(v_league.draft_seconds_remaining, 120)),
      draft_paused_at = null,
      draft_seconds_remaining = null,
      updated_at = clock_timestamp()
    where id = p_league_id;
  end if;
end;
$$;


ALTER FUNCTION "public"."set_league_draft_paused"("p_league_id" "uuid", "p_paused" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_league_draft_ready"("p_league_id" "uuid", "p_ready" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league public.leagues; v_user_id uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to get ready for the draft.'; end if;
  if p_ready is null then raise exception 'Choose ready or unready.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status <> 'setup' then
    raise exception 'Readiness can only change before a league draft starts.';
  end if;
  update public.league_members member
  set draft_ready_at = case when p_ready then clock_timestamp() else null end,
      updated_at = clock_timestamp()
  where member.league_id = p_league_id and member.user_id = auth.uid()
    and member.status = 'active' and member.role = 'member'
  returning member.user_id into v_user_id;
  if v_user_id is null then
    raise exception 'Only regular league members can change readiness.';
  end if;
end;
$$;


ALTER FUNCTION "public"."set_league_draft_ready"("p_league_id" "uuid", "p_ready" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_profile_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_profile_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_week_season_finale"("p_week_id" "uuid", "p_is_season_finale" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare v_week_number integer; v_last_number integer;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  select number into v_week_number from public.weeks where id = p_week_id for update;
  if v_week_number is null then raise exception 'Week not found.'; end if;
  select max(number) into v_last_number from public.weeks;
  if p_is_season_finale and v_week_number <> v_last_number then raise exception 'Only the last scheduled week can be marked as the season finale.'; end if;
  if coalesce(p_is_season_finale, false) then
    update public.weeks set is_season_finale = false where is_season_finale and id <> p_week_id;
  end if;
  update public.weeks set is_season_finale = coalesce(p_is_season_finale, false) where id = p_week_id;
end;
$$;


ALTER FUNCTION "public"."set_week_season_finale"("p_week_id" "uuid", "p_is_season_finale" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."snapshot_other_leagues_on_week_completion"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league record;
begin
  if new.is_complete and not old.is_complete then
    for v_league in select id from public.leagues
      where id <> public.default_fantasy_league_id() and status = 'active'
        and new.number > scoring_starts_after_week
    loop
      perform public.capture_secondary_league_week_snapshot(v_league.id, new.id);
    end loop;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."snapshot_other_leagues_on_week_completion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."start_league_draft"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform public.start_league_draft(p_league_id, false);
end;
$$;


ALTER FUNCTION "public"."start_league_draft"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."start_league_draft"("p_league_id" "uuid", "p_disable_timer" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league public.leagues; v_team_count integer;
begin
  if p_disable_timer is null then raise exception 'Choose a draft clock setting.'; end if;
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null or v_league.id = public.default_fantasy_league_id()
     or v_league.status <> 'setup' then
    raise exception 'The draft has already started or the league was not found.';
  end if;
  select count(*) into v_team_count from public.league_members
  where league_id = p_league_id and status = 'active';
  if v_team_count not between 3 and 6 then
    raise exception 'Invite 3 to 6 managers before starting the draft.';
  end if;
  if exists (select 1 from public.league_members member
    where member.league_id = p_league_id and member.status = 'active'
      and member.role = 'member' and member.draft_ready_at is null) then
    raise exception 'All regular managers must be ready before the draft starts.';
  end if;
  if v_team_count * v_league.roster_size > (select count(*) from public.cast_members) then
    raise exception 'There are not enough cast members for this roster size.';
  end if;
  insert into public.league_draft_order (league_id, draft_position, fantasy_team_id)
  select p_league_id, row_number() over (order by random(), member.user_id),
    member.fantasy_team_id
  from public.league_members member
  where member.league_id = p_league_id and member.status = 'active';
  update public.league_invites set status = 'cancelled', responded_at = now()
  where league_id = p_league_id and status = 'pending';
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  update public.leagues set status = 'drafting', draft_started_at = now(),
    draft_timer_disabled = p_disable_timer, draft_paused_at = null,
    draft_seconds_remaining = null, updated_at = now()
  where id = p_league_id;
end;
$$;


ALTER FUNCTION "public"."start_league_draft"("p_league_id" "uuid", "p_disable_timer" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."suggest_league_roster_size"("p_member_count" integer) RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select case when p_member_count >= 5 then 8
              when p_member_count = 4 then 10
              else 12 end;
$$;


ALTER FUNCTION "public"."suggest_league_roster_size"("p_member_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."swap_available_cast_member_into_team"("p_team_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_my_team_id uuid;
begin
  select fantasy_team_id into v_my_team_id from public.league_members
  where league_id = public.default_fantasy_league_id() and user_id = auth.uid();
  if v_my_team_id is distinct from p_team_id then raise exception 'You may only claim for your own team.'; end if;
  if not exists (select 1 from public.fantasy_teams
    where id = p_team_id and league_id = public.default_fantasy_league_id()) then
    raise exception 'Fantasy team not found.';
  end if;
  if p_incoming_cast_member_id = p_outgoing_cast_member_id then raise exception 'Choose different cast members.'; end if;
  perform 1 from public.cast_members
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id) order by id for update;
  if (select fantasy_team_id from public.cast_members where id = p_incoming_cast_member_id) is not null then
    raise exception 'Incoming cast is no longer available.';
  end if;
  if (select fantasy_team_id from public.cast_members where id = p_outgoing_cast_member_id) is distinct from p_team_id then
    raise exception 'Outgoing cast is no longer on your team.';
  end if;
  perform public.expire_trade_offers_locked();
  if exists (select 1 from public.trade_offers
    where league_id = public.default_fantasy_league_id()
      and (initiator_cast_member_id = p_outgoing_cast_member_id
        or counterparty_cast_member_id = p_outgoing_cast_member_id)) then
    raise exception 'This cast member has an active trade offer.';
  end if;
  update public.cast_members set fantasy_team_id = case
    when id = p_incoming_cast_member_id then p_team_id else null end
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id);
end;
$$;


ALTER FUNCTION "public"."swap_available_cast_member_into_team"("p_team_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_default_league_role_rate"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.league_role_rates (league_id, role_id, appearance_points, updated_at)
  values (public.default_fantasy_league_id(), new.id, new.appearance_points, now())
  on conflict (league_id, role_id) do update
  set appearance_points = excluded.appearance_points, updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_default_league_role_rate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_default_league_roster_assignment"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_default_league_id uuid := public.default_fantasy_league_id();
  v_team_league_id uuid;
begin
  delete from public.league_roster_assignments
  where league_id = v_default_league_id and cast_member_id = new.id;

  if new.fantasy_team_id is not null then
    select league_id into v_team_league_id from public.fantasy_teams where id = new.fantasy_team_id;
    if v_team_league_id is distinct from v_default_league_id then
      raise exception 'The legacy roster field may only represent the default league.';
    end if;
    insert into public.league_roster_assignments (league_id, cast_member_id, fantasy_team_id)
    values (v_default_league_id, new.id, new.fantasy_team_id);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_default_league_roster_assignment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_league_settings_name"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.leagues
  set name = new.league_name, updated_at = now()
  where id = new.league_id;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_league_settings_name"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_legacy_commissioner_flag"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  new.is_commissioner := new.league_id = public.default_fantasy_league_id()
    and new.role = 'owner' and new.status = 'active';
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_legacy_commissioner_flag"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_partnership_after_cast_role_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  update public.partnerships pair
  set active = star.role = 'Star' and pro.role = 'Pro'
  from public.cast_members star, public.cast_members pro
  where pair.star_id = star.id and pair.pro_id = pro.id
    and (pair.star_id = new.id or pair.pro_id = new.id)
    and pair.active is distinct from (star.role = 'Star' and pro.role = 'Pro');
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_partnership_after_cast_role_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_profile_compatibility_names"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_first_name text;
  v_last_name text;
begin
  v_first_name := left(split_part(new.display_name, ' ', 1), 40);
  v_last_name := nullif(left(trim(substr(new.display_name, char_length(split_part(new.display_name, ' ', 1)) + 1)), 50), '');

  update public.league_members
  set first_name = v_first_name,
      last_name = v_last_name,
      updated_at = now()
  where user_id = new.user_id;

  update public.fantasy_teams team
  set manager_name = new.display_name
  from public.league_members member
  where member.user_id = new.user_id
    and member.fantasy_team_id = team.id;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_profile_compatibility_names"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_cast_profile_details"("p_cast_member_id" "uuid", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare v_role text; v_is_hough boolean;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if p_mirrorball_wins is null or p_mirrorball_wins < 0 or p_mirrorball_wins > 99 then raise exception 'Past wins must be from 0 to 99.'; end if;
  select role, is_hough into v_role, v_is_hough from public.cast_members where id = p_cast_member_id for update;
  if not found then raise exception 'Cast member not found.'; end if;
  if p_mirrorball_wins <> 0 and not (v_role in ('Pro','Eliminated Pro') or (v_role = 'Judges + Hosts' and v_is_hough)) then
    raise exception 'Past Mirrorball wins are available only for pros and Hough judges or hosts.';
  end if;
  update public.cast_members set bio = nullif(trim(p_bio), ''), career_highlights = nullif(trim(p_career_highlights), ''), mirrorball_wins = p_mirrorball_wins where id = p_cast_member_id;
end;
$$;


ALTER FUNCTION "public"."update_cast_profile_details"("p_cast_member_id" "uuid", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_completed_week_details"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_week public.weeks%rowtype;
  v_old_guest text;
  v_new_guest text := nullif(trim(p_guest_judge_name), '');
  v_eliminated_couples integer;
  v_expected_eliminations integer;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if not v_week.is_complete then raise exception 'Use the regular week editor until this week is complete.'; end if;
  if p_second_air_date is not null and p_air_date is null then raise exception 'Choose the first airing date before adding a second night.'; end if;
  if p_second_air_date is not null and p_second_air_date < p_air_date then raise exception 'The second night cannot be before the first night.'; end if;
  if v_new_guest is not null and lower(v_new_guest) = any(array['carrie ann','derek','bruno']::text[]) then raise exception 'The guest judge name must differ from the regular judges.'; end if;

  select count(*) into v_eliminated_couples
  from public.partnerships pair
  join public.cast_members star on star.id = pair.star_id
  join public.cast_members pro on pro.id = pair.pro_id
  where star.eliminated_week_id = p_week_id and pro.eliminated_week_id = p_week_id;
  v_expected_eliminations := case when p_is_finale then 0 when p_double_elimination then 2 else 1 end;
  if v_eliminated_couples <> v_expected_eliminations then
    raise exception 'This format expects % eliminated couple(s), but this week has % recorded.', v_expected_eliminations, v_eliminated_couples;
  end if;

  v_old_guest := nullif(trim(v_week.guest_judge_name), '');
  if v_old_guest is distinct from v_new_guest then
    if exists (select 1 from public.dances where week_id = p_week_id and kind = 'competitive')
       and (v_old_guest is null or v_new_guest is null) then
      raise exception 'After completion, you can rename the recorded guest judge but cannot add or remove one.';
    end if;
    if v_old_guest is not null and v_new_guest is not null then
      update public.dance_judge_scores score set judge_name = v_new_guest
      from public.dances dance
      where score.dance_id = dance.id and dance.week_id = p_week_id and score.judge_name = v_old_guest;
    end if;
  end if;

  update public.weeks set theme = nullif(trim(p_theme), ''), title = nullif(trim(p_title), ''),
    air_date = p_air_date, second_air_date = p_second_air_date, guest_judge_name = v_new_guest,
    double_elimination = case when p_is_finale then false else p_double_elimination end,
    is_finale = p_is_finale where id = p_week_id;
end;
$$;


ALTER FUNCTION "public"."update_completed_week_details"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_completed_week_details_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_is_season_finale" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  perform public.update_completed_week_details(p_week_id, p_theme, p_title, p_air_date, p_second_air_date, p_guest_judge_name, p_double_elimination, p_is_finale);
  perform public.set_week_season_finale(p_week_id, p_is_season_finale);
end;
$$;


ALTER FUNCTION "public"."update_completed_week_details_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_is_season_finale" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_league_name"("p_league_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_league_commissioner() then
    raise exception 'Commissioner access is required.';
  end if;

  if nullif(trim(p_league_name), '') is null or char_length(trim(p_league_name)) > 80 then
    raise exception 'League name must be from 1 to 80 characters.';
  end if;

  insert into public.league_settings (id, league_name, updated_at)
  values (1, trim(p_league_name), now())
  on conflict (id) do update
    set league_name = excluded.league_name,
        updated_at = excluded.updated_at;
end;
$$;


ALTER FUNCTION "public"."update_league_name"("p_league_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_league_role_rates"("p_league_id" "uuid", "p_rates" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare v_rate jsonb; v_role_id uuid; v_points integer;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  if jsonb_typeof(p_rates) is distinct from 'array' then raise exception 'Rates must be a list.'; end if;
  for v_rate in select value from jsonb_array_elements(p_rates) loop
    if coalesce(v_rate->>'appearance_points', '') !~ '^[0-9]{1,2}$' then
      raise exception 'Rates must be whole numbers from 0 to 99.';
    end if;
    v_points := (v_rate->>'appearance_points')::integer;
    select id into v_role_id from public.roles where name = v_rate->>'name';
    if v_role_id is null then raise exception 'Unknown role.'; end if;
    insert into public.league_role_rates (league_id, role_id, appearance_points)
    values (p_league_id, v_role_id, v_points)
    on conflict (league_id, role_id) do update
      set appearance_points = excluded.appearance_points, updated_at = now();
  end loop;
end;
$_$;


ALTER FUNCTION "public"."update_league_role_rates"("p_league_id" "uuid", "p_rates" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_league_team_name"("p_league_id" "uuid", "p_team_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_team_id uuid;
begin
  select fantasy_team_id into v_team_id from public.league_members
  where league_id = p_league_id and user_id = auth.uid() and status = 'active';
  if v_team_id is null then raise exception 'League membership required.'; end if;
  if char_length(trim(coalesce(p_team_name, ''))) > 80 then raise exception 'Team name must be 80 characters or fewer.'; end if;
  update public.fantasy_teams set team_name = nullif(trim(coalesce(p_team_name, '')), '')
  where id = v_team_id and league_id = p_league_id;
end;
$$;


ALTER FUNCTION "public"."update_league_team_name"("p_league_id" "uuid", "p_team_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform public.update_league_workspace(p_league_id, p_name, p_roster_size, null::boolean);
end;
$$;


ALTER FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer, "p_auto_roster" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league public.leagues; v_members integer; v_size integer;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null then raise exception 'League not found.'; end if;
  if char_length(trim(coalesce(p_name, ''))) not between 1 and 80 then
    raise exception 'League name must be 1–80 characters.';
  end if;
  select count(*) into v_members from public.league_members
    where league_id = p_league_id and status = 'active';
  v_size := case when p_auto_roster is true or p_roster_size is null
    then public.suggest_league_roster_size(v_members) else p_roster_size end;
  if v_size not between 1 and 30 then raise exception 'Roster size must be 1–30.'; end if;
  if v_members * v_size > (select count(*) from public.cast_members) then
    raise exception 'Roster size × managers cannot exceed the cast pool.';
  end if;
  if v_league.status <> 'setup' and (v_size is distinct from v_league.roster_size
      or (p_auto_roster is not null and p_auto_roster = v_league.roster_size_overridden)) then
    raise exception 'Roster size is locked after the draft starts.';
  end if;
  update public.leagues set name = trim(p_name), roster_size = v_size,
    roster_size_overridden = case when p_auto_roster is true then false
      when p_auto_roster is false then true
      when p_roster_size is null then false
      when v_size is distinct from v_league.roster_size then true
      else v_league.roster_size_overridden end,
    updated_at = now() where id = p_league_id;
end;
$$;


ALTER FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer, "p_auto_roster" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_members" (
    "user_id" "uuid" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "fantasy_team_id" "uuid",
    "is_commissioner" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "team_nav_label_mode" "text" DEFAULT 'default'::"text" NOT NULL,
    "custom_team_nav_label" "text",
    "league_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "draft_ready_at" timestamp with time zone,
    CONSTRAINT "league_members_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'member'::"text"]))),
    CONSTRAINT "league_members_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'removed'::"text"]))),
    CONSTRAINT "league_members_team_nav_label_mode_check" CHECK (("team_nav_label_mode" = ANY (ARRAY['default'::"text", 'team'::"text", 'custom'::"text"])))
);


ALTER TABLE "public"."league_members" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_my_league_name"("p_first_name" "text", "p_last_name" "text") RETURNS "public"."league_members"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_member public.league_members;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  update public.profiles
  set display_name = trim(concat_ws(' ', nullif(trim(p_first_name), ''), nullif(trim(p_last_name), '')))
  where user_id = auth.uid();
  select * into v_member from public.league_members
  where league_id = public.default_fantasy_league_id() and user_id = auth.uid();
  if v_member.user_id is null then raise exception 'This account has not been added to the league.'; end if;
  return v_member;
end;
$$;


ALTER FUNCTION "public"."update_my_league_name"("p_first_name" "text", "p_last_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_my_profile"("p_username" "text", "p_display_name" "text", "p_avatar_url" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_profile public.profiles;
  v_username text := lower(trim(coalesce(p_username, '')));
  v_display_name text := trim(coalesce(p_display_name, ''));
  v_avatar_url text := nullif(trim(coalesce(p_avatar_url, '')), '');
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if v_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Username must be 3–20 characters using lowercase letters, numbers, or underscores.';
  end if;
  if char_length(v_display_name) not between 1 and 80 then
    raise exception 'Display name must be between 1 and 80 characters.';
  end if;
  if v_avatar_url is not null and (char_length(v_avatar_url) > 2048 or v_avatar_url !~* '^https://') then
    raise exception 'Avatar URL must be a valid HTTPS address.';
  end if;

  update public.profiles
  set username = v_username,
      display_name = v_display_name,
      avatar_url = v_avatar_url,
      onboarding_completed = true
  where user_id = auth.uid()
  returning * into v_profile;

  if v_profile.user_id is null then raise exception 'Your profile could not be found.'; end if;
  return to_jsonb(v_profile);
exception when unique_violation then
  raise exception 'That username is already taken.';
end;
$_$;


ALTER FUNCTION "public"."update_my_profile"("p_username" "text", "p_display_name" "text", "p_avatar_url" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_my_team_profile"("p_first_name" "text", "p_last_name" "text", "p_team_name" "text", "p_nav_label_mode" "text" DEFAULT 'default'::"text", "p_custom_nav_label" "text" DEFAULT NULL::"text") RETURNS "public"."league_members"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_member public.league_members;
begin
  perform public.update_my_team_settings(
    trim(concat_ws(' ', nullif(trim(p_first_name), ''), nullif(trim(p_last_name), ''))),
    p_team_name, p_nav_label_mode, p_custom_nav_label
  );
  select * into v_member from public.league_members
  where league_id = public.default_fantasy_league_id() and user_id = auth.uid();
  return v_member;
end;
$$;


ALTER FUNCTION "public"."update_my_team_profile"("p_first_name" "text", "p_last_name" "text", "p_team_name" "text", "p_nav_label_mode" "text", "p_custom_nav_label" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_my_team_settings"("p_display_name" "text", "p_team_name" "text", "p_nav_label_mode" "text" DEFAULT 'default'::"text", "p_custom_nav_label" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_league_id uuid := public.default_fantasy_league_id();
  v_team_id uuid;
  v_member public.league_members;
  v_display_name text := trim(coalesce(p_display_name, ''));
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if char_length(v_display_name) not between 1 and 80 then raise exception 'Display name must be between 1 and 80 characters.'; end if;
  if p_nav_label_mode not in ('default', 'team', 'custom') then raise exception 'Invalid My Team label option.'; end if;
  if p_nav_label_mode = 'team' and nullif(trim(coalesce(p_team_name, '')), '') is null then raise exception 'Add a team name first.'; end if;
  if p_nav_label_mode = 'custom' and nullif(trim(coalesce(p_custom_nav_label, '')), '') is null then raise exception 'Enter a custom My Team label.'; end if;

  select fantasy_team_id into v_team_id
  from public.league_members
  where league_id = v_league_id and user_id = auth.uid();
  if v_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;

  update public.profiles set display_name = v_display_name where user_id = auth.uid();
  update public.league_members
  set team_nav_label_mode = p_nav_label_mode,
      custom_team_nav_label = case when p_nav_label_mode = 'custom' then trim(p_custom_nav_label) else null end,
      updated_at = now()
  where league_id = v_league_id and user_id = auth.uid()
  returning * into v_member;
  update public.fantasy_teams set team_name = nullif(trim(coalesce(p_team_name, '')), '') where id = v_team_id;

  return jsonb_build_object('membership', to_jsonb(v_member), 'team_name', nullif(trim(coalesce(p_team_name, '')), ''));
end;
$$;


ALTER FUNCTION "public"."update_my_team_settings"("p_display_name" "text", "p_team_name" "text", "p_nav_label_mode" "text", "p_custom_nav_label" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_role_rates_atomic"("p_rates" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $_$
declare v_rate jsonb;
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if jsonb_typeof(p_rates) is distinct from 'array' then raise exception 'Role rates must be a list.'; end if;
  for v_rate in select value from jsonb_array_elements(p_rates) loop
    if coalesce(v_rate->>'name', '') = 'Surprise' then raise exception 'Surprise rates are set per cast member.'; end if;
    if coalesce(v_rate->>'appearance_points', '') !~ '^[0-9]{1,2}$' then raise exception 'Every rate must be a whole number from 0 to 99.'; end if;
    update public.roles set appearance_points = (v_rate->>'appearance_points')::integer where name = v_rate->>'name';
    if not found then raise exception 'Unknown role: %.', coalesce(v_rate->>'name', '(blank)'); end if;
  end loop;
end;
$_$;


ALTER FUNCTION "public"."update_role_rates_atomic"("p_rates" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_team_profile_atomic"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid" DEFAULT NULL::"uuid", "p_first_name" "text" DEFAULT NULL::"text", "p_last_name" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform public.update_team_profile_from_profile(
    p_team_id, p_team_name, p_manager_user_id,
    case when p_manager_user_id is null then null
         else trim(concat_ws(' ', nullif(trim(p_first_name), ''), nullif(trim(p_last_name), ''))) end
  );
end;
$$;


ALTER FUNCTION "public"."update_team_profile_atomic"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_team_profile_from_profile"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid" DEFAULT NULL::"uuid", "p_display_name" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare v_league_id uuid := public.default_fantasy_league_id();
begin
  if auth.uid() is null or not exists (
    select 1 from public.league_members
    where league_id = v_league_id and user_id = auth.uid() and is_commissioner
  ) then raise exception 'Commissioner access is required.'; end if;
  if p_manager_user_id is not null or p_display_name is not null then
    raise exception 'Only members can change their own display names.';
  end if;
  if char_length(trim(coalesce(p_team_name, ''))) > 80 then
    raise exception 'Team name must be 80 characters or fewer.';
  end if;
  update public.fantasy_teams
  set team_name = nullif(trim(coalesce(p_team_name, '')), '')
  where id = p_team_id and league_id = v_league_id;
  if not found then raise exception 'Fantasy team not found.'; end if;
end;
$$;


ALTER FUNCTION "public"."update_team_profile_from_profile"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid", "p_display_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_week_setup_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  perform public.update_week_setup_dates_and_order(p_week_id, p_theme, p_title, p_guest_judge_name, p_double_elimination, p_is_finale, p_dance_ids, p_air_date, p_second_air_date);
  perform public.set_week_season_finale(p_week_id, p_is_season_finale);
end;
$$;


ALTER FUNCTION "public"."update_week_setup_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_week_setup_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
declare
  v_week public.weeks%rowtype;
  v_ids uuid[] := coalesce(p_dance_ids, '{}'::uuid[]);
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if v_week.is_complete then raise exception 'A completed week’s setup cannot be edited.'; end if;
  if cardinality(v_ids) <> (select count(*) from public.dances where week_id = p_week_id)
     or cardinality(v_ids) <> (select count(distinct id) from unnest(v_ids) as id)
     or exists (select 1 from unnest(v_ids) as id where not exists (select 1 from public.dances where week_id = p_week_id and public.dances.id = id)) then
    raise exception 'The dance list changed. Reload this week and try again.';
  end if;
  if p_guest_judge_name is not null and nullif(trim(p_guest_judge_name), '') is null then raise exception 'Enter a guest judge name or turn off the guest judge option.'; end if;
  if p_guest_judge_name is not null and lower(trim(p_guest_judge_name)) = any(array['carrie ann','derek','bruno']::text[]) then raise exception 'The guest judge name must differ from the regular judges.'; end if;
  if exists (
    select 1 from public.dance_judge_scores s join public.dances d on d.id = s.dance_id
    where d.week_id = p_week_id and d.kind = 'competitive'
      and not (s.judge_name = any(array['Carrie Ann','Derek','Bruno']::text[] ||
        case when nullif(trim(p_guest_judge_name), '') is null then '{}'::text[] else array[trim(p_guest_judge_name)] end))
  ) then raise exception 'Existing scores use a different guest judge. Edit those dances first.'; end if;
  update public.weeks set theme = nullif(trim(p_theme), ''), title = nullif(trim(p_title), ''),
    guest_judge_name = nullif(trim(p_guest_judge_name), ''),
    double_elimination = case when p_is_finale then false else p_double_elimination end,
    is_finale = p_is_finale where id = p_week_id;
  update public.dances d set sort_order = ordered.ordinal::integer
  from unnest(v_ids) with ordinality as ordered(id, ordinal)
  where d.id = ordered.id and d.week_id = p_week_id;
end;
$$;


ALTER FUNCTION "public"."update_week_setup_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_week_setup_dates_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if p_second_air_date is not null and p_air_date is null then
    raise exception 'Choose the first airing date before adding a second night.';
  end if;
  if p_second_air_date is not null and p_second_air_date < p_air_date then
    raise exception 'The second night cannot be before the first night.';
  end if;

  perform public.update_week_setup_and_order(
    p_week_id,
    p_theme,
    p_title,
    p_guest_judge_name,
    p_double_elimination,
    p_is_finale,
    p_dance_ids
  );

  update public.weeks
  set air_date = p_air_date,
      second_air_date = p_second_air_date
  where id = p_week_id;
end;
$$;


ALTER FUNCTION "public"."update_week_setup_dates_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_week_setup_with_market_schedule"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean, "p_air_start_time" time without time zone, "p_air_end_time" time without time zone, "p_second_air_start_time" time without time zone, "p_second_air_end_time" time without time zone, "p_elimination_predictions_enabled" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.is_platform_admin() then
    raise exception 'Platform-owner access is required.';
  end if;
  if p_air_start_time is null or p_air_end_time is null or p_air_start_time >= p_air_end_time then
    raise exception 'The first airing end time must be after its start time.';
  end if;
  if p_second_air_date is not null and
     (p_second_air_start_time is null or p_second_air_end_time is null
      or p_second_air_start_time >= p_second_air_end_time) then
    raise exception 'The second airing end time must be after its start time.';
  end if;
  if p_elimination_predictions_enabled and p_air_date is null then
    raise exception 'Set an air date before enabling weekly elimination predictions.';
  end if;
  perform public.update_week_setup_and_finale(p_week_id, p_theme, p_title,
    p_guest_judge_name, p_double_elimination, p_is_finale, p_dance_ids,
    p_air_date, p_second_air_date, p_is_season_finale);
  update public.weeks set
    air_start_time = p_air_start_time,
    air_end_time = p_air_end_time,
    second_air_start_time = case when p_second_air_date is null then null else p_second_air_start_time end,
    second_air_end_time = case when p_second_air_date is null then null else p_second_air_end_time end,
    elimination_predictions_enabled = coalesce(p_elimination_predictions_enabled, false) and not p_is_finale
  where id = p_week_id;
end;
$$;


ALTER FUNCTION "public"."update_week_setup_with_market_schedule"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean, "p_air_start_time" time without time zone, "p_air_end_time" time without time zone, "p_second_air_start_time" time without time zone, "p_second_air_end_time" time without time zone, "p_elimination_predictions_enabled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_season_finale_week"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' and exists (select 1 from public.weeks where is_season_finale) then
    raise exception 'The season finale is already scheduled. Unmark it before adding another week.';
  end if;
  if new.is_season_finale and exists (select 1 from public.weeks where id <> new.id and number > new.number) then
    raise exception 'Only the last scheduled week can be marked as the season finale.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."validate_season_finale_week"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cast_market_prediction_history" (
    "market_ticker" "text" NOT NULL,
    "event_ticker" "text" NOT NULL,
    "cast_member_id" "uuid" NOT NULL,
    "market_kind" "text" NOT NULL,
    "week_id" "uuid",
    "snapshot_bucket" timestamp with time zone NOT NULL,
    "observed_at" timestamp with time zone NOT NULL,
    "quote_at" timestamp with time zone,
    "percent" numeric(5,1) NOT NULL,
    "bid_percent" numeric(5,1),
    "ask_percent" numeric(5,1),
    "last_percent" numeric(5,1),
    "quote_source" "text" NOT NULL,
    "market_status" "text" NOT NULL,
    "source" "text" DEFAULT 'live'::"text" NOT NULL,
    CONSTRAINT "cast_market_prediction_history_ask_percent_check" CHECK ((("ask_percent" >= (0)::numeric) AND ("ask_percent" <= (100)::numeric))),
    CONSTRAINT "cast_market_prediction_history_bid_percent_check" CHECK ((("bid_percent" >= (0)::numeric) AND ("bid_percent" <= (100)::numeric))),
    CONSTRAINT "cast_market_prediction_history_check" CHECK ((("market_kind" = 'elimination'::"text") = ("week_id" IS NOT NULL))),
    CONSTRAINT "cast_market_prediction_history_last_percent_check" CHECK ((("last_percent" >= (0)::numeric) AND ("last_percent" <= (100)::numeric))),
    CONSTRAINT "cast_market_prediction_history_market_kind_check" CHECK (("market_kind" = ANY (ARRAY['winner'::"text", 'second'::"text", 'third'::"text", 'top_three'::"text", 'finalist'::"text", 'elimination'::"text"]))),
    CONSTRAINT "cast_market_prediction_history_percent_check" CHECK ((("percent" >= (0)::numeric) AND ("percent" <= (100)::numeric))),
    CONSTRAINT "cast_market_prediction_history_quote_source_check" CHECK (("quote_source" = ANY (ARRAY['midpoint'::"text", 'last'::"text"]))),
    CONSTRAINT "cast_market_prediction_history_source_check" CHECK (("source" = ANY (ARRAY['live'::"text", 'historical_backfill'::"text"])))
);


ALTER TABLE "public"."cast_market_prediction_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cast_market_predictions" (
    "market_ticker" "text" NOT NULL,
    "event_ticker" "text" NOT NULL,
    "cast_member_id" "uuid" NOT NULL,
    "market_kind" "text" NOT NULL,
    "week_id" "uuid",
    "percent" numeric(5,1),
    "market_status" "text" NOT NULL,
    "market_result" "text",
    "fetched_at" timestamp with time zone NOT NULL,
    "bid_percent" numeric(5,1),
    "ask_percent" numeric(5,1),
    "quote_source" "text",
    CONSTRAINT "cast_market_predictions_check" CHECK ((("market_kind" = 'elimination'::"text") = ("week_id" IS NOT NULL))),
    CONSTRAINT "cast_market_predictions_market_kind_check" CHECK (("market_kind" = ANY (ARRAY['winner'::"text", 'second'::"text", 'third'::"text", 'top_three'::"text", 'finalist'::"text", 'elimination'::"text"]))),
    CONSTRAINT "cast_market_predictions_percent_check" CHECK ((("percent" >= (0)::numeric) AND ("percent" <= (100)::numeric)))
);


ALTER TABLE "public"."cast_market_predictions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cast_market_symbols" (
    "cast_member_id" "uuid" NOT NULL,
    "ticker_suffix" "text" NOT NULL,
    CONSTRAINT "cast_market_symbols_ticker_suffix_check" CHECK (("ticker_suffix" ~ '^[A-Z0-9]{2,8}$'::"text"))
);


ALTER TABLE "public"."cast_market_symbols" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cast_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "role" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "image_path" "text",
    "role_id" "uuid",
    "custom_appearance_points" integer,
    "eliminated_week_id" "uuid",
    "fantasy_team_id" "uuid",
    "image_position" integer DEFAULT 50 NOT NULL,
    "role_detail" "text",
    "is_hough" boolean DEFAULT false NOT NULL,
    "bio" "text",
    "career_highlights" "text",
    "mirrorball_wins" integer DEFAULT 0 NOT NULL,
    "profile_details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "surprise_base_role" "text",
    CONSTRAINT "cast_members_image_position_check" CHECK ((("image_position" >= 0) AND ("image_position" <= 100))),
    CONSTRAINT "cast_members_mirrorball_wins_check" CHECK ((("mirrorball_wins" >= 0) AND ("mirrorball_wins" <= 99))),
    CONSTRAINT "cast_members_mirrorball_wins_role_check" CHECK ((("mirrorball_wins" = 0) OR ("role" = ANY (ARRAY['Pro'::"text", 'Eliminated Pro'::"text"])) OR (("role" = 'Judges + Hosts'::"text") AND "is_hough"))),
    CONSTRAINT "cast_members_role_detail_check" CHECK ((("role_detail" IS NULL) OR ("role_detail" = ANY (ARRAY['Judge'::"text", 'Host'::"text", 'Judge + Host'::"text"])))),
    CONSTRAINT "cast_members_surprise_base_role_check" CHECK ((("surprise_base_role" IS NULL) OR ("surprise_base_role" = ANY (ARRAY['Eliminated Pro'::"text", 'Eliminated Star'::"text", 'Troupe'::"text", 'DWTS Next Pro'::"text", 'Judges + Hosts'::"text"])))),
    CONSTRAINT "players_role_check" CHECK (("role" = ANY (ARRAY['Star'::"text", 'Pro'::"text", 'Eliminated Star'::"text", 'Eliminated Pro'::"text", 'Troupe'::"text", 'DWTS Next Pro'::"text", 'Hough'::"text", 'Judges + Hosts'::"text", 'Surprise'::"text"]))),
    CONSTRAINT "players_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'eliminated'::"text"])))
);


ALTER TABLE "public"."cast_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dance_appearances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dance_id" "uuid" NOT NULL,
    "cast_member_id" "uuid" NOT NULL
);


ALTER TABLE "public"."dance_appearances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dance_judge_scores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dance_id" "uuid" NOT NULL,
    "judge_name" "text" NOT NULL,
    "score" integer NOT NULL,
    CONSTRAINT "dance_judge_scores_score_check" CHECK ((("score" >= 0) AND ("score" <= 10)))
);


ALTER TABLE "public"."dance_judge_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "week_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "partnership_id" "uuid",
    "name" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "dance_type" "text",
    "song" "text",
    CONSTRAINT "dances_kind_check" CHECK (("kind" = ANY (ARRAY['competitive'::"text", 'performance'::"text"]))),
    CONSTRAINT "dances_kind_partnership_shape" CHECK (((("kind" = 'competitive'::"text") AND ("partnership_id" IS NOT NULL)) OR (("kind" = 'performance'::"text") AND ("partnership_id" IS NULL))))
);


ALTER TABLE "public"."dances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fantasy_teams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "manager_name" "text" NOT NULL,
    "team_name" "text",
    "league_id" "uuid" NOT NULL
);


ALTER TABLE "public"."fantasy_teams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_draft_order" (
    "league_id" "uuid" NOT NULL,
    "draft_position" integer NOT NULL,
    "fantasy_team_id" "uuid" NOT NULL,
    CONSTRAINT "league_draft_order_draft_position_check" CHECK (("draft_position" >= 1))
);


ALTER TABLE "public"."league_draft_order" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_draft_picks" (
    "league_id" "uuid" NOT NULL,
    "pick_number" integer NOT NULL,
    "round_number" integer NOT NULL,
    "fantasy_team_id" "uuid" NOT NULL,
    "cast_member_id" "uuid" NOT NULL,
    "picked_by" "uuid" NOT NULL,
    "picked_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_auto_pick" boolean DEFAULT false NOT NULL,
    CONSTRAINT "league_draft_picks_pick_number_check" CHECK (("pick_number" >= 1)),
    CONSTRAINT "league_draft_picks_round_number_check" CHECK (("round_number" >= 1))
);


ALTER TABLE "public"."league_draft_picks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_invite_code_attempts" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "attempted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."league_invite_code_attempts" OWNER TO "postgres";


ALTER TABLE "public"."league_invite_code_attempts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."league_invite_code_attempts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."league_invite_links" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "token_hash" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '14 days'::interval) NOT NULL,
    "revoked_at" timestamp with time zone,
    "code_hash" "text",
    "token_value" "text",
    "code_value" "text"
);


ALTER TABLE "public"."league_invite_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "inviter_id" "uuid" NOT NULL,
    "invitee_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "responded_at" timestamp with time zone,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '14 days'::interval) NOT NULL,
    CONSTRAINT "league_invites_check" CHECK (("inviter_id" <> "invitee_id")),
    CONSTRAINT "league_invites_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."league_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_role_rates" (
    "league_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "appearance_points" integer,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "league_role_rates_appearance_points_check" CHECK ((("appearance_points" >= 0) AND ("appearance_points" <= 99)))
);


ALTER TABLE "public"."league_role_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_roster_assignments" (
    "league_id" "uuid" NOT NULL,
    "cast_member_id" "uuid" NOT NULL,
    "fantasy_team_id" "uuid" NOT NULL,
    "assigned_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."league_roster_assignments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_settings" (
    "id" smallint DEFAULT 1 NOT NULL,
    "league_name" "text" DEFAULT 'DWTS Fantasy League'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    CONSTRAINT "league_settings_id_check" CHECK (("id" = 1)),
    CONSTRAINT "league_settings_league_name_check" CHECK ((("char_length"(TRIM(BOTH FROM "league_name")) >= 1) AND ("char_length"(TRIM(BOTH FROM "league_name")) <= 80)))
);


ALTER TABLE "public"."league_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_trade_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "trade_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "initiator_team_id" "uuid" NOT NULL,
    "counterparty_team_id" "uuid" NOT NULL,
    "initiator_cast_member_name" "text" NOT NULL,
    "counterparty_cast_member_name" "text" NOT NULL,
    "notification_team_id" "uuid",
    "dismissed_at" timestamp with time zone,
    "event_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "league_trade_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['countered'::"text", 'accepted'::"text", 'denied'::"text", 'cancelled'::"text", 'expired'::"text", 'invalidated'::"text"])))
);


ALTER TABLE "public"."league_trade_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_weekly_roster_snapshots" (
    "league_id" "uuid" NOT NULL,
    "week_id" "uuid" NOT NULL,
    "cast_member_id" "uuid" NOT NULL,
    "fantasy_team_id" "uuid",
    "cast_member_name" "text" NOT NULL,
    "cast_role" "text" NOT NULL,
    "appearance_points" integer,
    "manager_name" "text",
    "team_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."league_weekly_roster_snapshots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leagues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "created_by" "uuid",
    "status" "text" DEFAULT 'setup'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "roster_size" integer DEFAULT 11 NOT NULL,
    "is_public" boolean DEFAULT false NOT NULL,
    "draft_started_at" timestamp with time zone,
    "draft_completed_at" timestamp with time zone,
    "scoring_starts_after_week" integer DEFAULT 0 NOT NULL,
    "roster_size_overridden" boolean DEFAULT false NOT NULL,
    "draft_pick_deadline_at" timestamp with time zone,
    "draft_paused_at" timestamp with time zone,
    "draft_seconds_remaining" integer,
    "draft_timer_disabled" boolean DEFAULT false NOT NULL,
    "draft_airing_paused_at" timestamp with time zone,
    "draft_airing_seconds_remaining" integer,
    "shared_workspace_enabled" boolean DEFAULT true NOT NULL,
    CONSTRAINT "leagues_draft_airing_seconds_remaining_check" CHECK ((("draft_airing_seconds_remaining" >= 0) AND ("draft_airing_seconds_remaining" <= 120))),
    CONSTRAINT "leagues_draft_seconds_remaining_check" CHECK ((("draft_seconds_remaining" >= 0) AND ("draft_seconds_remaining" <= 120))),
    CONSTRAINT "leagues_name_check" CHECK ((("char_length"(TRIM(BOTH FROM "name")) >= 1) AND ("char_length"(TRIM(BOTH FROM "name")) <= 80))),
    CONSTRAINT "leagues_roster_size_check" CHECK ((("roster_size" >= 1) AND ("roster_size" <= 30))),
    CONSTRAINT "leagues_status_check" CHECK (("status" = ANY (ARRAY['setup'::"text", 'drafting'::"text", 'active'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."leagues" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."market_prediction_sync_state" (
    "id" integer DEFAULT 1 NOT NULL,
    "refreshed_at" timestamp with time zone,
    "snapshot_bucket" timestamp with time zone,
    CONSTRAINT "market_prediction_sync_state_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."market_prediction_sync_state" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partnerships" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "star_id" "uuid",
    "pro_id" "uuid",
    "active" boolean DEFAULT true NOT NULL,
    "partnership_name" "text"
);


ALTER TABLE "public"."partnerships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platform_admins" (
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."platform_admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "avatar_url" "text",
    "onboarding_completed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "profiles_avatar_url_check" CHECK ((("avatar_url" IS NULL) OR (("avatar_url" = TRIM(BOTH FROM "avatar_url")) AND ("char_length"("avatar_url") <= 2048) AND ("avatar_url" ~* '^https://'::"text")))),
    CONSTRAINT "profiles_display_name_check" CHECK ((("display_name" = TRIM(BOTH FROM "display_name")) AND (("char_length"("display_name") >= 1) AND ("char_length"("display_name") <= 80)))),
    CONSTRAINT "profiles_username_format_check" CHECK ((("username" = "lower"("username")) AND (("char_length"("username") >= 3) AND ("char_length"("username") <= 20)) AND ("username" ~ '^[a-z0-9_]+$'::"text")))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."profile_directory" WITH ("security_invoker"='true') AS
 SELECT "user_id",
    "username",
    "display_name",
    "avatar_url"
   FROM "public"."profiles";


ALTER VIEW "public"."profile_directory" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "appearance_points" integer,
    "allows_custom_appearance_points" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roster_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid" NOT NULL,
    "fantasy_team_id" "uuid",
    "starts_week_id" "uuid",
    "ends_week_id" "uuid"
);


ALTER TABLE "public"."roster_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "week_id" "uuid" NOT NULL,
    "player_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "points" integer NOT NULL,
    "label" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "score_events_kind_check" CHECK (("kind" = ANY (ARRAY['official'::"text", 'appearance'::"text"]))),
    CONSTRAINT "score_events_points_check" CHECK (("points" >= 0))
);


ALTER TABLE "public"."score_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."weekly_role_rates" (
    "week_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "appearance_points" integer NOT NULL,
    CONSTRAINT "weekly_role_rates_appearance_points_check" CHECK ((("appearance_points" >= 0) AND ("appearance_points" <= 99)))
);


ALTER TABLE "public"."weekly_role_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."weekly_roster_snapshots" (
    "week_id" "uuid" NOT NULL,
    "cast_member_id" "uuid" NOT NULL,
    "fantasy_team_id" "uuid",
    "cast_member_name" "text" NOT NULL,
    "cast_role" "text" NOT NULL,
    "manager_name" "text",
    "team_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "appearance_points" integer,
    "league_id" "uuid" NOT NULL
);


ALTER TABLE "public"."weekly_roster_snapshots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."weeks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "number" integer NOT NULL,
    "label" "text",
    "is_published" boolean DEFAULT false NOT NULL,
    "theme" "text",
    "title" "text",
    "guest_judge_name" "text",
    "double_elimination" boolean DEFAULT false NOT NULL,
    "is_finale" boolean DEFAULT false NOT NULL,
    "is_complete" boolean DEFAULT false NOT NULL,
    "uses_rate_snapshots" boolean DEFAULT false NOT NULL,
    "air_date" "date",
    "second_air_date" "date",
    "is_season_finale" boolean DEFAULT false NOT NULL,
    "air_start_time" time without time zone DEFAULT '20:00:00'::time without time zone NOT NULL,
    "air_end_time" time without time zone DEFAULT '22:00:00'::time without time zone NOT NULL,
    "second_air_start_time" time without time zone,
    "second_air_end_time" time without time zone,
    "elimination_predictions_enabled" boolean DEFAULT false NOT NULL,
    CONSTRAINT "week_prediction_airing_times_valid" CHECK ((("air_start_time" < "air_end_time") AND (("second_air_start_time" IS NULL) OR ("second_air_end_time" IS NULL) OR ("second_air_start_time" < "second_air_end_time")))),
    CONSTRAINT "weeks_air_dates_ordered" CHECK ((("second_air_date" IS NULL) OR (("air_date" IS NOT NULL) AND ("second_air_date" >= "air_date"))))
);


ALTER TABLE "public"."weeks" OWNER TO "postgres";


ALTER TABLE ONLY "public"."cast_market_prediction_history"
    ADD CONSTRAINT "cast_market_prediction_history_pkey" PRIMARY KEY ("market_ticker", "snapshot_bucket");



ALTER TABLE ONLY "public"."cast_market_predictions"
    ADD CONSTRAINT "cast_market_predictions_pkey" PRIMARY KEY ("market_ticker");



ALTER TABLE ONLY "public"."cast_market_symbols"
    ADD CONSTRAINT "cast_market_symbols_pkey" PRIMARY KEY ("cast_member_id");



ALTER TABLE ONLY "public"."cast_market_symbols"
    ADD CONSTRAINT "cast_market_symbols_ticker_suffix_key" UNIQUE ("ticker_suffix");



ALTER TABLE ONLY "public"."dance_appearances"
    ADD CONSTRAINT "dance_appearances_dance_id_cast_member_id_key" UNIQUE ("dance_id", "cast_member_id");



ALTER TABLE ONLY "public"."dance_appearances"
    ADD CONSTRAINT "dance_appearances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dance_judge_scores"
    ADD CONSTRAINT "dance_judge_scores_dance_id_judge_name_key" UNIQUE ("dance_id", "judge_name");



ALTER TABLE ONLY "public"."dance_judge_scores"
    ADD CONSTRAINT "dance_judge_scores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dances"
    ADD CONSTRAINT "dances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fantasy_teams"
    ADD CONSTRAINT "fantasy_teams_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."fantasy_teams"
    ADD CONSTRAINT "fantasy_teams_team_name_length_check" CHECK ((("team_name" IS NULL) OR (("char_length"("team_name") >= 1) AND ("char_length"("team_name") <= 80)))) NOT VALID;



ALTER TABLE ONLY "public"."league_draft_order"
    ADD CONSTRAINT "league_draft_order_league_id_fantasy_team_id_key" UNIQUE ("league_id", "fantasy_team_id");



ALTER TABLE ONLY "public"."league_draft_order"
    ADD CONSTRAINT "league_draft_order_pkey" PRIMARY KEY ("league_id", "draft_position");



ALTER TABLE ONLY "public"."league_draft_picks"
    ADD CONSTRAINT "league_draft_picks_league_id_cast_member_id_key" UNIQUE ("league_id", "cast_member_id");



ALTER TABLE ONLY "public"."league_draft_picks"
    ADD CONSTRAINT "league_draft_picks_pkey" PRIMARY KEY ("league_id", "pick_number");



ALTER TABLE ONLY "public"."league_invite_code_attempts"
    ADD CONSTRAINT "league_invite_code_attempts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_invite_links"
    ADD CONSTRAINT "league_invite_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_invite_links"
    ADD CONSTRAINT "league_invite_links_token_hash_key" UNIQUE ("token_hash");



ALTER TABLE ONLY "public"."league_invites"
    ADD CONSTRAINT "league_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."league_members"
    ADD CONSTRAINT "league_members_custom_nav_length_check" CHECK ((("custom_team_nav_label" IS NULL) OR (("char_length"("custom_team_nav_label") >= 1) AND ("char_length"("custom_team_nav_label") <= 24)))) NOT VALID;



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_fantasy_team_id_key" UNIQUE ("fantasy_team_id");



ALTER TABLE "public"."league_members"
    ADD CONSTRAINT "league_members_first_name_length_check" CHECK ((("first_name" IS NULL) OR (("char_length"(TRIM(BOTH FROM "first_name")) >= 1) AND ("char_length"(TRIM(BOTH FROM "first_name")) <= 40)))) NOT VALID;



ALTER TABLE "public"."league_members"
    ADD CONSTRAINT "league_members_last_name_length_check" CHECK ((("last_name" IS NULL) OR (("char_length"(TRIM(BOTH FROM "last_name")) >= 1) AND ("char_length"(TRIM(BOTH FROM "last_name")) <= 50)))) NOT VALID;



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_pkey" PRIMARY KEY ("league_id", "user_id");



ALTER TABLE ONLY "public"."league_role_rates"
    ADD CONSTRAINT "league_role_rates_pkey" PRIMARY KEY ("league_id", "role_id");



ALTER TABLE ONLY "public"."league_roster_assignments"
    ADD CONSTRAINT "league_roster_assignments_pkey" PRIMARY KEY ("league_id", "cast_member_id");



ALTER TABLE ONLY "public"."league_settings"
    ADD CONSTRAINT "league_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_trade_events"
    ADD CONSTRAINT "league_trade_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_weekly_roster_snapshots"
    ADD CONSTRAINT "league_weekly_roster_snapshots_pkey" PRIMARY KEY ("league_id", "week_id", "cast_member_id");



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."market_prediction_sync_state"
    ADD CONSTRAINT "market_prediction_sync_state_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partnerships"
    ADD CONSTRAINT "partnerships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partnerships"
    ADD CONSTRAINT "partnerships_pro_id_key" UNIQUE ("pro_id");



ALTER TABLE ONLY "public"."partnerships"
    ADD CONSTRAINT "partnerships_star_id_key" UNIQUE ("star_id");



ALTER TABLE ONLY "public"."platform_admins"
    ADD CONSTRAINT "platform_admins_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."cast_members"
    ADD CONSTRAINT "players_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."cast_members"
    ADD CONSTRAINT "players_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roster_history"
    ADD CONSTRAINT "roster_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."weekly_role_rates"
    ADD CONSTRAINT "weekly_role_rates_pkey" PRIMARY KEY ("week_id", "role");



ALTER TABLE ONLY "public"."weekly_roster_snapshots"
    ADD CONSTRAINT "weekly_roster_snapshots_pkey" PRIMARY KEY ("league_id", "week_id", "cast_member_id");



ALTER TABLE ONLY "public"."weeks"
    ADD CONSTRAINT "weeks_number_key" UNIQUE ("number");



ALTER TABLE ONLY "public"."weeks"
    ADD CONSTRAINT "weeks_pkey" PRIMARY KEY ("id");



CREATE INDEX "cast_market_prediction_history_chart_idx" ON "public"."cast_market_prediction_history" USING "btree" ("cast_member_id", "market_kind", "observed_at");



CREATE INDEX "cast_market_predictions_cast_week_idx" ON "public"."cast_market_predictions" USING "btree" ("cast_member_id", "week_id", "market_kind");



CREATE INDEX "cast_members_fantasy_team_name_idx" ON "public"."cast_members" USING "btree" ("fantasy_team_id", "name") WHERE ("fantasy_team_id" IS NOT NULL);



CREATE INDEX "dance_appearances_cast_member_idx" ON "public"."dance_appearances" USING "btree" ("cast_member_id", "dance_id");



CREATE INDEX "dances_partnership_idx" ON "public"."dances" USING "btree" ("partnership_id") WHERE ("partnership_id" IS NOT NULL);



CREATE INDEX "dances_week_kind_sort_idx" ON "public"."dances" USING "btree" ("week_id", "kind", "sort_order", "id");



CREATE UNIQUE INDEX "fantasy_teams_league_id_id_key" ON "public"."fantasy_teams" USING "btree" ("league_id", "id");



CREATE INDEX "league_invite_code_attempts_user_time_idx" ON "public"."league_invite_code_attempts" USING "btree" ("user_id", "attempted_at" DESC);



CREATE UNIQUE INDEX "league_invite_links_code_hash_idx" ON "public"."league_invite_links" USING "btree" ("code_hash") WHERE ("code_hash" IS NOT NULL);



CREATE UNIQUE INDEX "league_invite_links_one_live_idx" ON "public"."league_invite_links" USING "btree" ("league_id") WHERE ("revoked_at" IS NULL);



CREATE INDEX "league_invites_inbox_idx" ON "public"."league_invites" USING "btree" ("invitee_id", "status", "created_at" DESC);



CREATE UNIQUE INDEX "league_invites_one_pending_idx" ON "public"."league_invites" USING "btree" ("league_id", "invitee_id") WHERE ("status" = 'pending'::"text");



CREATE UNIQUE INDEX "league_members_league_team_key" ON "public"."league_members" USING "btree" ("league_id", "fantasy_team_id") WHERE ("fantasy_team_id" IS NOT NULL);



CREATE UNIQUE INDEX "league_members_one_owner_idx" ON "public"."league_members" USING "btree" ("league_id") WHERE (("role" = 'owner'::"text") AND ("status" = 'active'::"text"));



CREATE INDEX "league_members_user_id_idx" ON "public"."league_members" USING "btree" ("user_id");



CREATE UNIQUE INDEX "league_settings_league_id_key" ON "public"."league_settings" USING "btree" ("league_id");



CREATE INDEX "league_trade_events_teams_idx" ON "public"."league_trade_events" USING "btree" ("league_id", "event_at" DESC);



CREATE INDEX "league_trade_offers_team_idx" ON "public"."league_trade_offers" USING "btree" ("league_id", "awaiting_team_id", "updated_at" DESC);



CREATE INDEX "league_weekly_snapshots_team_week_idx" ON "public"."league_weekly_roster_snapshots" USING "btree" ("league_id", "fantasy_team_id", "week_id");



CREATE UNIQUE INDEX "one_competitive_dance_per_pair_per_week" ON "public"."dances" USING "btree" ("week_id", "partnership_id") WHERE ("kind" = 'competitive'::"text");



CREATE UNIQUE INDEX "one_season_finale" ON "public"."weeks" USING "btree" ("is_season_finale") WHERE "is_season_finale";



CREATE UNIQUE INDEX "profiles_username_lower_key" ON "public"."profiles" USING "btree" ("lower"("username"));



CREATE INDEX "trade_history_counterparty_team_idx" ON "public"."trade_history" USING "btree" ("counterparty_team_id", "event_at" DESC);



CREATE INDEX "trade_history_initiator_team_idx" ON "public"."trade_history" USING "btree" ("initiator_team_id", "event_at" DESC);



CREATE INDEX "trade_history_league_event_idx" ON "public"."trade_history" USING "btree" ("league_id", "event_at" DESC);



CREATE INDEX "trade_history_trade_event_idx" ON "public"."trade_history" USING "btree" ("trade_id", "event_at" DESC);



CREATE INDEX "trade_history_unread_result_idx" ON "public"."trade_history" USING "btree" ("notification_team_id", "event_at" DESC) WHERE (("notification_team_id" IS NOT NULL) AND ("dismissed_at" IS NULL));



CREATE INDEX "trade_offers_awaiting_team_idx" ON "public"."trade_offers" USING "btree" ("awaiting_team_id", "updated_at" DESC);



CREATE INDEX "trade_offers_counterparty_cast_idx" ON "public"."trade_offers" USING "btree" ("counterparty_cast_member_id");



CREATE INDEX "trade_offers_counterparty_team_idx" ON "public"."trade_offers" USING "btree" ("counterparty_team_id", "updated_at" DESC);



CREATE INDEX "trade_offers_expiration_idx" ON "public"."trade_offers" USING "btree" ("expires_at");



CREATE INDEX "trade_offers_initiator_cast_idx" ON "public"."trade_offers" USING "btree" ("initiator_cast_member_id");



CREATE INDEX "trade_offers_initiator_team_idx" ON "public"."trade_offers" USING "btree" ("initiator_team_id", "updated_at" DESC);



CREATE INDEX "trade_offers_league_updated_idx" ON "public"."trade_offers" USING "btree" ("league_id", "updated_at" DESC);



CREATE INDEX "weekly_roster_snapshots_cast_week_idx" ON "public"."weekly_roster_snapshots" USING "btree" ("cast_member_id", "week_id");



CREATE UNIQUE INDEX "weekly_roster_snapshots_legacy_week_cast_key" ON "public"."weekly_roster_snapshots" USING "btree" ("week_id", "cast_member_id");



CREATE INDEX "weekly_roster_snapshots_team_week_idx" ON "public"."weekly_roster_snapshots" USING "btree" ("fantasy_team_id", "week_id") WHERE ("fantasy_team_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "activate_drafted_league_snapshots" AFTER UPDATE OF "status" ON "public"."leagues" FOR EACH ROW EXECUTE FUNCTION "public"."activate_drafted_league_snapshots"();



CREATE OR REPLACE TRIGGER "advance_league_draft_deadline_after_pick" AFTER INSERT ON "public"."league_draft_picks" FOR EACH ROW EXECUTE FUNCTION "public"."advance_league_draft_deadline_after_pick"();



CREATE OR REPLACE TRIGGER "check_balanced_draft_capacity" BEFORE UPDATE OF "status" ON "public"."leagues" FOR EACH ROW EXECUTE FUNCTION "public"."check_balanced_draft_capacity"();



CREATE OR REPLACE TRIGGER "check_league_membership_capacity" BEFORE INSERT OR UPDATE OF "status" ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."check_league_membership_capacity"();



CREATE OR REPLACE TRIGGER "check_secondary_league_trade_role_limits" BEFORE INSERT OR UPDATE OF "initiator_cast_member_id", "counterparty_cast_member_id" ON "public"."league_trade_offers" FOR EACH ROW EXECUTE FUNCTION "public"."check_secondary_league_trade_role_limits"();



CREATE OR REPLACE TRIGGER "check_user_league_membership_limit" BEFORE INSERT OR UPDATE OF "user_id", "status" ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."check_user_league_membership_limit"();



CREATE OR REPLACE TRIGGER "enforce_league_draft_pick_clock" BEFORE INSERT ON "public"."league_draft_picks" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_league_draft_pick_clock"();



CREATE OR REPLACE TRIGGER "enforce_league_draft_role_reserves" AFTER INSERT OR UPDATE OF "fantasy_team_id" ON "public"."league_roster_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_league_draft_role_reserves"();



CREATE OR REPLACE TRIGGER "enforce_member_profile_name" BEFORE INSERT OR UPDATE OF "user_id", "first_name", "last_name" ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_member_profile_name"();



CREATE OR REPLACE TRIGGER "enforce_preset_league_roster_size" BEFORE INSERT OR UPDATE ON "public"."leagues" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_preset_league_roster_size"();



CREATE OR REPLACE TRIGGER "enforce_secondary_league_category_limit" AFTER INSERT OR UPDATE OF "fantasy_team_id" ON "public"."league_roster_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_secondary_league_category_limit"();



CREATE OR REPLACE TRIGGER "enforce_team_profile_name" BEFORE INSERT OR UPDATE OF "manager_name" ON "public"."fantasy_teams" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_team_profile_name"();



CREATE OR REPLACE TRIGGER "fantasy_teams_default_league_scope" BEFORE INSERT ON "public"."fantasy_teams" FOR EACH ROW EXECUTE FUNCTION "public"."apply_default_league_scope"();



CREATE OR REPLACE TRIGGER "guard_default_legacy_trade_path" BEFORE INSERT OR UPDATE ON "public"."trade_offers" FOR EACH ROW EXECUTE FUNCTION "public"."guard_default_legacy_trade_path"();



CREATE OR REPLACE TRIGGER "guard_default_shared_trade_path" BEFORE INSERT OR UPDATE ON "public"."league_trade_offers" FOR EACH ROW EXECUTE FUNCTION "public"."guard_default_shared_trade_path"();



CREATE OR REPLACE TRIGGER "guard_league_draft_start_airing_window" BEFORE UPDATE OF "status" ON "public"."leagues" FOR EACH ROW EXECUTE FUNCTION "public"."guard_league_draft_start_airing_window"();



CREATE OR REPLACE TRIGGER "guard_league_trade_airing_window" BEFORE INSERT OR UPDATE ON "public"."league_trade_offers" FOR EACH ROW EXECUTE FUNCTION "public"."guard_league_trade_airing_window"();



CREATE OR REPLACE TRIGGER "guard_secondary_league_roster_change" BEFORE INSERT OR DELETE OR UPDATE ON "public"."league_roster_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."guard_secondary_league_roster_change"();



CREATE OR REPLACE TRIGGER "initialize_league_invite_credentials" AFTER INSERT ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."initialize_league_invite_credentials"();



CREATE OR REPLACE TRIGGER "keep_eliminated_partnership_inactive" BEFORE INSERT OR UPDATE ON "public"."partnerships" FOR EACH ROW EXECUTE FUNCTION "public"."keep_eliminated_partnership_inactive"();



CREATE OR REPLACE TRIGGER "league_members_default_league_scope" BEFORE INSERT ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."apply_default_league_scope"();



CREATE OR REPLACE TRIGGER "league_settings_default_league_scope" BEFORE INSERT ON "public"."league_settings" FOR EACH ROW EXECUTE FUNCTION "public"."apply_default_league_scope"();



CREATE OR REPLACE TRIGGER "mirror_default_league_trade_history" AFTER INSERT OR UPDATE ON "public"."trade_history" FOR EACH ROW EXECUTE FUNCTION "public"."mirror_default_league_trade_history"();



CREATE OR REPLACE TRIGGER "mirror_default_league_week_snapshot" AFTER INSERT OR UPDATE ON "public"."weekly_roster_snapshots" FOR EACH ROW EXECUTE FUNCTION "public"."mirror_default_league_week_snapshot"();



CREATE OR REPLACE TRIGGER "prevent_competing_pair_appearance" BEFORE INSERT OR UPDATE ON "public"."dance_appearances" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_competing_pair_appearance"();



CREATE OR REPLACE TRIGGER "refresh_automatic_roster_size" AFTER INSERT OR DELETE OR UPDATE OF "status" ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."refresh_automatic_roster_size"();



CREATE OR REPLACE TRIGGER "seed_new_role_for_leagues" AFTER INSERT ON "public"."roles" FOR EACH ROW EXECUTE FUNCTION "public"."seed_new_role_for_leagues"();



CREATE OR REPLACE TRIGGER "set_league_draft_deadline" BEFORE UPDATE OF "status" ON "public"."leagues" FOR EACH ROW EXECUTE FUNCTION "public"."set_league_draft_deadline"();



CREATE OR REPLACE TRIGGER "set_profile_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."set_profile_updated_at"();



CREATE OR REPLACE TRIGGER "snapshot_other_leagues_on_week_completion" AFTER UPDATE OF "is_complete" ON "public"."weeks" FOR EACH ROW EXECUTE FUNCTION "public"."snapshot_other_leagues_on_week_completion"();



CREATE OR REPLACE TRIGGER "sync_default_league_role_rate" AFTER INSERT OR UPDATE OF "appearance_points" ON "public"."roles" FOR EACH ROW EXECUTE FUNCTION "public"."sync_default_league_role_rate"();



CREATE OR REPLACE TRIGGER "sync_default_league_roster_assignment" AFTER INSERT OR UPDATE OF "fantasy_team_id" ON "public"."cast_members" FOR EACH ROW EXECUTE FUNCTION "public"."sync_default_league_roster_assignment"();



CREATE OR REPLACE TRIGGER "sync_league_settings_name" AFTER INSERT OR UPDATE OF "league_name" ON "public"."league_settings" FOR EACH ROW EXECUTE FUNCTION "public"."sync_league_settings_name"();



CREATE OR REPLACE TRIGGER "sync_legacy_commissioner_flag" BEFORE INSERT OR UPDATE OF "league_id", "role", "status" ON "public"."league_members" FOR EACH ROW EXECUTE FUNCTION "public"."sync_legacy_commissioner_flag"();



CREATE OR REPLACE TRIGGER "sync_partnership_after_cast_role_change" AFTER UPDATE OF "role" ON "public"."cast_members" FOR EACH ROW WHEN (("old"."role" IS DISTINCT FROM "new"."role")) EXECUTE FUNCTION "public"."sync_partnership_after_cast_role_change"();



CREATE OR REPLACE TRIGGER "sync_profile_compatibility_names" AFTER INSERT OR UPDATE OF "display_name" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."sync_profile_compatibility_names"();



CREATE OR REPLACE TRIGGER "trade_history_league_scope" BEFORE INSERT ON "public"."trade_history" FOR EACH ROW EXECUTE FUNCTION "public"."apply_trade_history_league_scope"();



CREATE OR REPLACE TRIGGER "trade_offers_league_scope" BEFORE INSERT OR UPDATE OF "initiator_team_id", "counterparty_team_id" ON "public"."trade_offers" FOR EACH ROW EXECUTE FUNCTION "public"."apply_trade_offer_league_scope"();



CREATE OR REPLACE TRIGGER "validate_season_finale_week_trigger" BEFORE INSERT OR UPDATE OF "is_season_finale" ON "public"."weeks" FOR EACH ROW EXECUTE FUNCTION "public"."validate_season_finale_week"();



CREATE OR REPLACE TRIGGER "weekly_snapshots_default_league_scope" BEFORE INSERT ON "public"."weekly_roster_snapshots" FOR EACH ROW EXECUTE FUNCTION "public"."apply_default_league_scope"();



ALTER TABLE ONLY "public"."cast_market_prediction_history"
    ADD CONSTRAINT "cast_market_prediction_history_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cast_market_prediction_history"
    ADD CONSTRAINT "cast_market_prediction_history_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cast_market_predictions"
    ADD CONSTRAINT "cast_market_predictions_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cast_market_predictions"
    ADD CONSTRAINT "cast_market_predictions_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cast_market_symbols"
    ADD CONSTRAINT "cast_market_symbols_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cast_members"
    ADD CONSTRAINT "cast_members_fantasy_team_id_fkey" FOREIGN KEY ("fantasy_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."dance_appearances"
    ADD CONSTRAINT "dance_appearances_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."dance_appearances"
    ADD CONSTRAINT "dance_appearances_dance_id_fkey" FOREIGN KEY ("dance_id") REFERENCES "public"."dances"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dance_judge_scores"
    ADD CONSTRAINT "dance_judge_scores_dance_id_fkey" FOREIGN KEY ("dance_id") REFERENCES "public"."dances"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dances"
    ADD CONSTRAINT "dances_partnership_id_fkey" FOREIGN KEY ("partnership_id") REFERENCES "public"."partnerships"("id");



ALTER TABLE ONLY "public"."dances"
    ADD CONSTRAINT "dances_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fantasy_teams"
    ADD CONSTRAINT "fantasy_teams_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id");



ALTER TABLE ONLY "public"."league_draft_order"
    ADD CONSTRAINT "league_draft_order_league_id_fantasy_team_id_fkey" FOREIGN KEY ("league_id", "fantasy_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_draft_order"
    ADD CONSTRAINT "league_draft_order_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_draft_picks"
    ADD CONSTRAINT "league_draft_picks_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."league_draft_picks"
    ADD CONSTRAINT "league_draft_picks_league_id_fantasy_team_id_fkey" FOREIGN KEY ("league_id", "fantasy_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id");



ALTER TABLE ONLY "public"."league_draft_picks"
    ADD CONSTRAINT "league_draft_picks_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_draft_picks"
    ADD CONSTRAINT "league_draft_picks_picked_by_fkey" FOREIGN KEY ("picked_by") REFERENCES "public"."profiles"("user_id");



ALTER TABLE ONLY "public"."league_invite_code_attempts"
    ADD CONSTRAINT "league_invite_code_attempts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_invite_links"
    ADD CONSTRAINT "league_invite_links_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("user_id");



ALTER TABLE ONLY "public"."league_invite_links"
    ADD CONSTRAINT "league_invite_links_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_invites"
    ADD CONSTRAINT "league_invites_invitee_id_fkey" FOREIGN KEY ("invitee_id") REFERENCES "public"."profiles"("user_id");



ALTER TABLE ONLY "public"."league_invites"
    ADD CONSTRAINT "league_invites_inviter_id_fkey" FOREIGN KEY ("inviter_id") REFERENCES "public"."profiles"("user_id");



ALTER TABLE ONLY "public"."league_invites"
    ADD CONSTRAINT "league_invites_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_fantasy_team_id_fkey" FOREIGN KEY ("fantasy_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id");



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_league_team_fkey" FOREIGN KEY ("league_id", "fantasy_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id");



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_profile_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_members"
    ADD CONSTRAINT "league_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_role_rates"
    ADD CONSTRAINT "league_role_rates_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_role_rates"
    ADD CONSTRAINT "league_role_rates_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_roster_assignments"
    ADD CONSTRAINT "league_roster_assignments_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_roster_assignments"
    ADD CONSTRAINT "league_roster_assignments_fantasy_team_id_fkey" FOREIGN KEY ("fantasy_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_roster_assignments"
    ADD CONSTRAINT "league_roster_assignments_league_id_fantasy_team_id_fkey" FOREIGN KEY ("league_id", "fantasy_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_roster_assignments"
    ADD CONSTRAINT "league_roster_assignments_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_settings"
    ADD CONSTRAINT "league_settings_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id");



ALTER TABLE ONLY "public"."league_trade_events"
    ADD CONSTRAINT "league_trade_events_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_awaiting_team_id_fkey" FOREIGN KEY ("awaiting_team_id") REFERENCES "public"."fantasy_teams"("id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_counterparty_cast_member_id_fkey" FOREIGN KEY ("counterparty_cast_member_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_counterparty_team_id_fkey" FOREIGN KEY ("counterparty_team_id") REFERENCES "public"."fantasy_teams"("id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_initiator_cast_member_id_fkey" FOREIGN KEY ("initiator_cast_member_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_initiator_team_id_fkey" FOREIGN KEY ("initiator_team_id") REFERENCES "public"."fantasy_teams"("id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_league_id_counterparty_team_id_fkey" FOREIGN KEY ("league_id", "counterparty_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id");



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_trade_offers"
    ADD CONSTRAINT "league_trade_offers_league_id_initiator_team_id_fkey" FOREIGN KEY ("league_id", "initiator_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id");



ALTER TABLE ONLY "public"."league_weekly_roster_snapshots"
    ADD CONSTRAINT "league_weekly_roster_snapshots_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."league_weekly_roster_snapshots"
    ADD CONSTRAINT "league_weekly_roster_snapshots_fantasy_team_id_fkey" FOREIGN KEY ("fantasy_team_id") REFERENCES "public"."fantasy_teams"("id");



ALTER TABLE ONLY "public"."league_weekly_roster_snapshots"
    ADD CONSTRAINT "league_weekly_roster_snapshots_league_id_fantasy_team_id_fkey" FOREIGN KEY ("league_id", "fantasy_team_id") REFERENCES "public"."fantasy_teams"("league_id", "id");



ALTER TABLE ONLY "public"."league_weekly_roster_snapshots"
    ADD CONSTRAINT "league_weekly_roster_snapshots_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_weekly_roster_snapshots"
    ADD CONSTRAINT "league_weekly_roster_snapshots_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partnerships"
    ADD CONSTRAINT "partnerships_pro_id_fkey" FOREIGN KEY ("pro_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."partnerships"
    ADD CONSTRAINT "partnerships_star_id_fkey" FOREIGN KEY ("star_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."platform_admins"
    ADD CONSTRAINT "platform_admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."cast_members"
    ADD CONSTRAINT "players_eliminated_week_id_fkey" FOREIGN KEY ("eliminated_week_id") REFERENCES "public"."weeks"("id");



ALTER TABLE ONLY "public"."cast_members"
    ADD CONSTRAINT "players_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."roster_history"
    ADD CONSTRAINT "roster_history_ends_week_id_fkey" FOREIGN KEY ("ends_week_id") REFERENCES "public"."weeks"("id");



ALTER TABLE ONLY "public"."roster_history"
    ADD CONSTRAINT "roster_history_fantasy_team_id_fkey" FOREIGN KEY ("fantasy_team_id") REFERENCES "public"."fantasy_teams"("id");



ALTER TABLE ONLY "public"."roster_history"
    ADD CONSTRAINT "roster_history_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."roster_history"
    ADD CONSTRAINT "roster_history_starts_week_id_fkey" FOREIGN KEY ("starts_week_id") REFERENCES "public"."weeks"("id");



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."cast_members"("id");



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id");



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_counterparty_cast_member_id_fkey" FOREIGN KEY ("counterparty_cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_counterparty_team_id_fkey" FOREIGN KEY ("counterparty_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_initiator_cast_member_id_fkey" FOREIGN KEY ("initiator_cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_initiator_team_id_fkey" FOREIGN KEY ("initiator_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id");



ALTER TABLE ONLY "public"."trade_history"
    ADD CONSTRAINT "trade_history_notification_team_id_fkey" FOREIGN KEY ("notification_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_awaiting_team_id_fkey" FOREIGN KEY ("awaiting_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_counterparty_cast_member_id_fkey" FOREIGN KEY ("counterparty_cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_counterparty_team_id_fkey" FOREIGN KEY ("counterparty_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_initiator_cast_member_id_fkey" FOREIGN KEY ("initiator_cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_initiator_team_id_fkey" FOREIGN KEY ("initiator_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_offers"
    ADD CONSTRAINT "trade_offers_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id");



ALTER TABLE ONLY "public"."weekly_role_rates"
    ADD CONSTRAINT "weekly_role_rates_role_fkey" FOREIGN KEY ("role") REFERENCES "public"."roles"("name") ON UPDATE CASCADE;



ALTER TABLE ONLY "public"."weekly_role_rates"
    ADD CONSTRAINT "weekly_role_rates_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."weekly_roster_snapshots"
    ADD CONSTRAINT "weekly_roster_snapshots_cast_member_id_fkey" FOREIGN KEY ("cast_member_id") REFERENCES "public"."cast_members"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."weekly_roster_snapshots"
    ADD CONSTRAINT "weekly_roster_snapshots_fantasy_team_id_fkey" FOREIGN KEY ("fantasy_team_id") REFERENCES "public"."fantasy_teams"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."weekly_roster_snapshots"
    ADD CONSTRAINT "weekly_roster_snapshots_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id");



ALTER TABLE ONLY "public"."weekly_roster_snapshots"
    ADD CONSTRAINT "weekly_roster_snapshots_week_id_fkey" FOREIGN KEY ("week_id") REFERENCES "public"."weeks"("id") ON DELETE CASCADE;



ALTER TABLE "public"."cast_market_prediction_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cast_market_predictions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cast_market_symbols" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cast_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "commissioner writes roles" ON "public"."roles" FOR UPDATE TO "authenticated" USING ("public"."is_league_commissioner"()) WITH CHECK ("public"."is_league_commissioner"());



CREATE POLICY "commissioner writes roster history" ON "public"."roster_history" TO "authenticated" USING ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text"));



CREATE POLICY "commissioner writes rosters" ON "public"."roster_history" TO "authenticated" USING ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text"));



CREATE POLICY "commissioner writes score events" ON "public"."score_events" TO "authenticated" USING ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text"));



CREATE POLICY "commissioner writes scores" ON "public"."score_events" TO "authenticated" USING ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text"));



CREATE POLICY "commissioner writes weekly role rates" ON "public"."weekly_role_rates" TO "authenticated" USING ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text")) WITH CHECK ((("auth"."jwt"() ->> 'email'::"text") = 'herbfreddy@gmail.com'::"text"));



ALTER TABLE "public"."dance_appearances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dance_judge_scores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."dances" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fantasy_teams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "involved users read invitations" ON "public"."league_invites" FOR SELECT TO "authenticated" USING ((("invitee_id" = "auth"."uid"()) OR "public"."is_league_owner"("league_id")));



ALTER TABLE "public"."league_draft_order" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_draft_picks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_invite_code_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_invite_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_role_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_roster_assignments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_trade_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_trade_offers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_weekly_roster_snapshots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."leagues" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "legacy owner writes default teams" ON "public"."fantasy_teams" TO "authenticated" USING ((("league_id" = "public"."default_fantasy_league_id"()) AND "public"."is_league_commissioner"())) WITH CHECK ((("league_id" = "public"."default_fantasy_league_id"()) AND "public"."is_league_commissioner"()));



CREATE POLICY "managers read their trades" ON "public"."trade_offers" FOR SELECT TO "authenticated" USING ((("expires_at" > "now"()) AND (("initiator_team_id" = "public"."current_league_team_id"()) OR ("counterparty_team_id" = "public"."current_league_team_id"()))));



ALTER TABLE "public"."market_prediction_sync_state" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "members read draft order" ON "public"."league_draft_order" FOR SELECT TO "authenticated" USING ("public"."is_league_member"("league_id"));



CREATE POLICY "members read draft picks" ON "public"."league_draft_picks" FOR SELECT TO "authenticated" USING ("public"."is_league_member"("league_id"));



CREATE POLICY "members read league week snapshots" ON "public"."league_weekly_roster_snapshots" FOR SELECT TO "authenticated" USING ("public"."is_league_member"("league_id"));



CREATE POLICY "members read their league" ON "public"."league_members" FOR SELECT TO "authenticated" USING ("public"."is_league_member"("league_id"));



CREATE POLICY "owners read invite link metadata" ON "public"."league_invite_links" FOR SELECT TO "authenticated" USING ("public"."is_league_owner"("league_id"));



ALTER TABLE "public"."partnerships" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "platform owner writes cast members" ON "public"."cast_members" TO "authenticated" USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "platform owner writes dance appearances" ON "public"."dance_appearances" TO "authenticated" USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "platform owner writes dances" ON "public"."dances" TO "authenticated" USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "platform owner writes default snapshots" ON "public"."weekly_roster_snapshots" TO "authenticated" USING ((("league_id" = "public"."default_fantasy_league_id"()) AND "public"."is_platform_admin"())) WITH CHECK ((("league_id" = "public"."default_fantasy_league_id"()) AND "public"."is_platform_admin"()));



CREATE POLICY "platform owner writes judge scores" ON "public"."dance_judge_scores" TO "authenticated" USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "platform owner writes partnerships" ON "public"."partnerships" TO "authenticated" USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



CREATE POLICY "platform owner writes weeks" ON "public"."weeks" TO "authenticated" USING ("public"."is_platform_admin"()) WITH CHECK ("public"."is_platform_admin"());



ALTER TABLE "public"."platform_admins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles visible to self or league peers" ON "public"."profiles" FOR SELECT TO "authenticated" USING ("public"."can_view_profile"("user_id"));



CREATE POLICY "public read cast members" ON "public"."cast_members" FOR SELECT USING (true);



CREATE POLICY "public read dance appearances" ON "public"."dance_appearances" FOR SELECT USING (true);



CREATE POLICY "public read dances" ON "public"."dances" FOR SELECT USING (true);



CREATE POLICY "public read judge scores" ON "public"."dance_judge_scores" FOR SELECT USING (true);



CREATE POLICY "public read partnerships" ON "public"."partnerships" FOR SELECT USING (true);



CREATE POLICY "public read players" ON "public"."cast_members" FOR SELECT USING (true);



CREATE POLICY "public read roles" ON "public"."roles" FOR SELECT USING (true);



CREATE POLICY "public read rosters" ON "public"."roster_history" FOR SELECT USING (true);



CREATE POLICY "public read scores" ON "public"."score_events" FOR SELECT USING (true);



CREATE POLICY "public read weekly role rates" ON "public"."weekly_role_rates" FOR SELECT USING (true);



CREATE POLICY "public read weeks" ON "public"."weeks" FOR SELECT USING (true);



CREATE POLICY "read accessible fantasy teams" ON "public"."fantasy_teams" FOR SELECT TO "authenticated", "anon" USING ("public"."can_read_league"("league_id"));



CREATE POLICY "read accessible league settings" ON "public"."league_settings" FOR SELECT TO "authenticated", "anon" USING ("public"."can_read_league"("league_id"));



CREATE POLICY "read accessible leagues" ON "public"."leagues" FOR SELECT TO "authenticated", "anon" USING (("is_public" OR "public"."is_league_member"("id")));



CREATE POLICY "read accessible role rates" ON "public"."league_role_rates" FOR SELECT TO "authenticated", "anon" USING ("public"."can_read_league"("league_id"));



CREATE POLICY "read accessible roster assignments" ON "public"."league_roster_assignments" FOR SELECT TO "authenticated", "anon" USING ("public"."can_read_league"("league_id"));



CREATE POLICY "read accessible weekly roster snapshots" ON "public"."weekly_roster_snapshots" FOR SELECT TO "authenticated", "anon" USING ("public"."can_read_league"("league_id"));



CREATE POLICY "read cast market predictions" ON "public"."cast_market_predictions" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "read market prediction history" ON "public"."cast_market_prediction_history" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."roster_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."score_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trade participants read events" ON "public"."league_trade_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."league_members" "member"
  WHERE (("member"."league_id" = "league_trade_events"."league_id") AND ("member"."user_id" = "auth"."uid"()) AND ("member"."status" = 'active'::"text") AND ("member"."fantasy_team_id" = ANY (ARRAY["league_trade_events"."initiator_team_id", "league_trade_events"."counterparty_team_id"]))))));



CREATE POLICY "trade participants read offers" ON "public"."league_trade_offers" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."league_members" "member"
  WHERE (("member"."league_id" = "league_trade_offers"."league_id") AND ("member"."user_id" = "auth"."uid"()) AND ("member"."status" = 'active'::"text") AND ("member"."fantasy_team_id" = ANY (ARRAY["league_trade_offers"."initiator_team_id", "league_trade_offers"."counterparty_team_id"]))))));



ALTER TABLE "public"."trade_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trade_offers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users update own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."weekly_role_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."weekly_roster_snapshots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."weeks" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."accept_trade"("p_trade_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."accept_trade"("p_trade_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."activate_drafted_league_snapshots"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."advance_league_draft_clock"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."advance_league_draft_clock"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."advance_league_draft_clock_without_airing_lock"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."advance_league_draft_deadline_after_pick"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."apply_default_league_scope"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."apply_trade_history_league_scope"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."apply_trade_offer_league_scope"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."assign_cast_members_to_team"("p_team_id" "uuid", "p_cast_member_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_cast_members_to_team"("p_team_id" "uuid", "p_cast_member_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."backfill_drafted_league_weeks"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."can_read_league"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_read_league"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_read_league"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."can_view_profile"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_view_profile"("p_user_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."cancel_league_invite"("p_invite_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_league_invite"("p_invite_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."capture_due_secondary_league_snapshots"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."capture_secondary_league_week_snapshot"("p_league_id" "uuid", "p_week_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."check_balanced_draft_capacity"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."check_league_membership_capacity"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."check_secondary_league_trade_role_limits"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."check_user_league_membership_limit"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."claim_league_cast_member"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_league_cast_member"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."claim_league_cast_member_without_default"("p_league_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") FROM PUBLIC;



GRANT ALL ON FUNCTION "public"."complete_week"("p_week_id" "uuid", "p_eliminated_partnership_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."counter_trade"("p_trade_id" "uuid", "p_initiator_cast_member_id" "uuid", "p_counterparty_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."counter_trade"("p_trade_id" "uuid", "p_initiator_cast_member_id" "uuid", "p_counterparty_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_fantasy_league"("p_name" "text", "p_roster_size" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_fantasy_league"("p_name" "text", "p_roster_size" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_league_invite"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_league_invite"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_profile_for_auth_user"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."current_league_team_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_league_team_id"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."default_fantasy_league_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."default_fantasy_league_id"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."delete_cast_member_atomic"("p_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_cast_member_atomic"("p_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."delete_fantasy_league"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_fantasy_league"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."deny_trade"("p_trade_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."deny_trade"("p_trade_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."dismiss_league_trade_result"("p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dismiss_league_trade_result"("p_event_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."dismiss_trade_result"("p_history_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dismiss_trade_result"("p_history_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."enforce_league_draft_pick_clock"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."enforce_league_draft_role_reserves"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."enforce_member_profile_name"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."enforce_team_profile_name"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."expire_league_trade_offers"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."expire_trade_offers_locked"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."get_league_draft_readiness"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_league_draft_readiness"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_league_invite"("p_league_id" "uuid", "p_refresh" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_league_invite"("p_league_id" "uuid", "p_refresh" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_league_team_managers"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_league_team_managers"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_league_team_managers"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_account_context"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_account_context"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_league_invites"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_league_invites"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_league_trades"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_league_trades"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_leagues"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_leagues"() TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."trade_history" TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_trade_history"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_trade_history"() TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."trade_offers" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."trade_offers" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."trade_offers" TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_trade_offers"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_trade_offers"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_trade_result_notifications"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_trade_result_notifications"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."guard_default_legacy_trade_path"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."guard_default_shared_trade_path"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."guard_league_draft_start_airing_window"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."guard_league_trade_airing_window"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."initialize_league_invite_credentials"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."invite_username"("p_league_id" "uuid", "p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invite_username"("p_league_id" "uuid", "p_username" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_league_commissioner"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_league_commissioner"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_league_member"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_league_member"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_league_member"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_league_owner"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_league_owner"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_league_owner"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_platform_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_platform_admin"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."join_league_from_invite"("p_league_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."join_league_with_code"("p_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."join_league_with_code"("p_code" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."join_league_with_link"("p_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."join_league_with_link"("p_token" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."league_bonus_draft_limit"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."league_category_limit"("p_league_id" "uuid", "p_role" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."league_draft_airing_lock_start"("p_at" timestamp with time zone) FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."league_flex_allowance"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."league_pick_is_eligible"("p_league_id" "uuid", "p_team_id" "uuid", "p_cast_member_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."league_trade_airing_locked"("p_at" timestamp with time zone) FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."league_unreserved_active_role_count"("p_league_id" "uuid", "p_role" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."list_league_members"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_league_members"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."list_league_members"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."mirror_default_league_trade_history"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."mirror_default_league_week_snapshot"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."next_profile_username"("p_seed" "text", "p_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."preview_league_invite_link"("p_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preview_league_invite_link"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."preview_league_invite_link"("p_token" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."process_expired_league_drafts"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."profile_display_name_from_auth"("p_user" "auth"."users") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."profile_username_base"("p_seed" "text", "p_user_id" "uuid") FROM PUBLIC;



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_trade_offers" TO "service_role";
GRANT SELECT ON TABLE "public"."league_trade_offers" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."record_league_trade_event"("p_offer" "public"."league_trade_offers", "p_event_type" "text", "p_notify_team_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."record_trade_history_event"("p_trade" "public"."trade_offers", "p_event_type" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."refresh_automatic_roster_size"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."refresh_my_league_snapshots"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_my_league_snapshots"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."regenerate_league_invite_link"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."remove_cast_member_from_team"("p_cast_member_id" "uuid", "p_team_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_cast_member_from_team"("p_cast_member_id" "uuid", "p_team_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."remove_league_member"("p_league_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."remove_league_member"("p_league_id" "uuid", "p_user_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."request_league_trade"("p_league_id" "uuid", "p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_league_trade"("p_league_id" "uuid", "p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."request_trade"("p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_trade"("p_my_cast_member_id" "uuid", "p_requested_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."respond_to_league_invite"("p_invite_id" "uuid", "p_accept" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."respond_to_league_invite"("p_invite_id" "uuid", "p_accept" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."respond_to_league_trade"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text", "p_replacement_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."respond_to_league_trade"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text", "p_replacement_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."respond_to_league_trade_without_default"("p_offer_id" "uuid", "p_action" "text", "p_replace_side" "text", "p_replacement_cast_member_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."revoke_league_invite_link"("p_league_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."rotate_expired_league_invites"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."rotate_league_invite_credentials"("p_league_id" "uuid", "p_creator" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."save_cast_member_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_cast_member_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."save_cast_member_profile_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_cast_member_profile_atomic"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."save_cast_member_profile_with_surprise_role"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer, "p_surprise_base_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_cast_member_profile_with_surprise_role"("p_cast_member_id" "uuid", "p_name" "text", "p_role" "text", "p_image_path" "text", "p_image_position" integer, "p_custom_appearance_points" integer, "p_role_detail" "text", "p_is_hough" boolean, "p_partner_id" "uuid", "p_partnership_name" "text", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer, "p_surprise_base_role" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."save_dance_atomic"("p_week_id" "uuid", "p_dance_id" "uuid", "p_kind" "text", "p_partnership_id" "uuid", "p_name" "text", "p_dance_type" "text", "p_song" "text", "p_judge_scores" "jsonb", "p_cast_member_ids" "uuid"[], "p_scores_only" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_dance_atomic"("p_week_id" "uuid", "p_dance_id" "uuid", "p_kind" "text", "p_partnership_id" "uuid", "p_name" "text", "p_dance_type" "text", "p_song" "text", "p_judge_scores" "jsonb", "p_cast_member_ids" "uuid"[], "p_scores_only" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."seed_new_role_for_leagues"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."set_cast_partnership_atomic"("p_cast_member_id" "uuid", "p_role" "text", "p_partner_id" "uuid", "p_partnership_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_cast_partnership_atomic"("p_cast_member_id" "uuid", "p_role" "text", "p_partner_id" "uuid", "p_partnership_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_league_draft_deadline"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."set_league_draft_paused"("p_league_id" "uuid", "p_paused" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_league_draft_paused"("p_league_id" "uuid", "p_paused" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_league_draft_ready"("p_league_id" "uuid", "p_ready" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_league_draft_ready"("p_league_id" "uuid", "p_ready" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_profile_updated_at"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."set_week_season_finale"("p_week_id" "uuid", "p_is_season_finale" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_week_season_finale"("p_week_id" "uuid", "p_is_season_finale" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."snapshot_other_leagues_on_week_completion"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."start_league_draft"("p_league_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."start_league_draft"("p_league_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."start_league_draft"("p_league_id" "uuid", "p_disable_timer" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."start_league_draft"("p_league_id" "uuid", "p_disable_timer" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."suggest_league_roster_size"("p_member_count" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."swap_available_cast_member_into_team"("p_team_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."swap_available_cast_member_into_team"("p_team_id" "uuid", "p_incoming_cast_member_id" "uuid", "p_outgoing_cast_member_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."sync_default_league_role_rate"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."sync_default_league_roster_assignment"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."sync_league_settings_name"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."sync_legacy_commissioner_flag"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."sync_profile_compatibility_names"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."update_cast_profile_details"("p_cast_member_id" "uuid", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_cast_profile_details"("p_cast_member_id" "uuid", "p_bio" "text", "p_career_highlights" "text", "p_mirrorball_wins" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_completed_week_details"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_completed_week_details"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_completed_week_details_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_is_season_finale" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_completed_week_details_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_air_date" "date", "p_second_air_date" "date", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_is_season_finale" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_league_name"("p_league_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_league_name"("p_league_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_league_role_rates"("p_league_id" "uuid", "p_rates" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_league_role_rates"("p_league_id" "uuid", "p_rates" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_league_team_name"("p_league_id" "uuid", "p_team_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_league_team_name"("p_league_id" "uuid", "p_team_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer, "p_auto_roster" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_league_workspace"("p_league_id" "uuid", "p_name" "text", "p_roster_size" integer, "p_auto_roster" boolean) TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_members" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_members" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_members" TO "service_role";



REVOKE ALL ON FUNCTION "public"."update_my_league_name"("p_first_name" "text", "p_last_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_my_league_name"("p_first_name" "text", "p_last_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_my_profile"("p_username" "text", "p_display_name" "text", "p_avatar_url" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_my_profile"("p_username" "text", "p_display_name" "text", "p_avatar_url" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_my_team_profile"("p_first_name" "text", "p_last_name" "text", "p_team_name" "text", "p_nav_label_mode" "text", "p_custom_nav_label" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_my_team_profile"("p_first_name" "text", "p_last_name" "text", "p_team_name" "text", "p_nav_label_mode" "text", "p_custom_nav_label" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_my_team_settings"("p_display_name" "text", "p_team_name" "text", "p_nav_label_mode" "text", "p_custom_nav_label" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_my_team_settings"("p_display_name" "text", "p_team_name" "text", "p_nav_label_mode" "text", "p_custom_nav_label" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_role_rates_atomic"("p_rates" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_role_rates_atomic"("p_rates" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_team_profile_atomic"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_team_profile_atomic"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid", "p_first_name" "text", "p_last_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_team_profile_from_profile"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid", "p_display_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_team_profile_from_profile"("p_team_id" "uuid", "p_team_name" "text", "p_manager_user_id" "uuid", "p_display_name" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_week_setup_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_week_setup_and_finale"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_week_setup_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_week_setup_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_week_setup_dates_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_week_setup_dates_and_order"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_week_setup_with_market_schedule"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean, "p_air_start_time" time without time zone, "p_air_end_time" time without time zone, "p_second_air_start_time" time without time zone, "p_second_air_end_time" time without time zone, "p_elimination_predictions_enabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_week_setup_with_market_schedule"("p_week_id" "uuid", "p_theme" "text", "p_title" "text", "p_guest_judge_name" "text", "p_double_elimination" boolean, "p_is_finale" boolean, "p_dance_ids" "uuid"[], "p_air_date" "date", "p_second_air_date" "date", "p_is_season_finale" boolean, "p_air_start_time" time without time zone, "p_air_end_time" time without time zone, "p_second_air_start_time" time without time zone, "p_second_air_end_time" time without time zone, "p_elimination_predictions_enabled" boolean) TO "authenticated";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."cast_market_prediction_history" TO "service_role";
GRANT SELECT ON TABLE "public"."cast_market_prediction_history" TO "anon";
GRANT SELECT ON TABLE "public"."cast_market_prediction_history" TO "authenticated";



GRANT ALL ON TABLE "public"."cast_market_predictions" TO "service_role";
GRANT SELECT ON TABLE "public"."cast_market_predictions" TO "anon";
GRANT SELECT ON TABLE "public"."cast_market_predictions" TO "authenticated";



GRANT ALL ON TABLE "public"."cast_market_symbols" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."cast_members" TO "anon";
GRANT ALL ON TABLE "public"."cast_members" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."cast_members" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dance_appearances" TO "anon";
GRANT ALL ON TABLE "public"."dance_appearances" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dance_appearances" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dance_judge_scores" TO "anon";
GRANT ALL ON TABLE "public"."dance_judge_scores" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dance_judge_scores" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dances" TO "anon";
GRANT ALL ON TABLE "public"."dances" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dances" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."fantasy_teams" TO "anon";
GRANT ALL ON TABLE "public"."fantasy_teams" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."fantasy_teams" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_draft_order" TO "service_role";
GRANT SELECT ON TABLE "public"."league_draft_order" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_draft_picks" TO "service_role";
GRANT SELECT ON TABLE "public"."league_draft_picks" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_invite_code_attempts" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_invite_links" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."league_invite_links" TO "authenticated";



GRANT SELECT("league_id") ON TABLE "public"."league_invite_links" TO "authenticated";



GRANT SELECT("created_by") ON TABLE "public"."league_invite_links" TO "authenticated";



GRANT SELECT("created_at") ON TABLE "public"."league_invite_links" TO "authenticated";



GRANT SELECT("expires_at") ON TABLE "public"."league_invite_links" TO "authenticated";



GRANT SELECT("revoked_at") ON TABLE "public"."league_invite_links" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_invites" TO "service_role";
GRANT SELECT ON TABLE "public"."league_invites" TO "authenticated";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_role_rates" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_role_rates" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_role_rates" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_roster_assignments" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_roster_assignments" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_roster_assignments" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_settings" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_settings" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_settings" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_trade_events" TO "service_role";
GRANT SELECT ON TABLE "public"."league_trade_events" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."league_weekly_roster_snapshots" TO "service_role";
GRANT SELECT ON TABLE "public"."league_weekly_roster_snapshots" TO "authenticated";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."leagues" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."leagues" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."leagues" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."market_prediction_sync_state" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."partnerships" TO "anon";
GRANT ALL ON TABLE "public"."partnerships" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."partnerships" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."platform_admins" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profiles" TO "service_role";



GRANT SELECT("user_id") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("username") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("display_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT("avatar_url") ON TABLE "public"."profiles" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profile_directory" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profile_directory" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profile_directory" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."roles" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."roles" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."roles" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."roster_history" TO "anon";
GRANT ALL ON TABLE "public"."roster_history" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."roster_history" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."score_events" TO "anon";
GRANT ALL ON TABLE "public"."score_events" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."score_events" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."weekly_role_rates" TO "anon";
GRANT ALL ON TABLE "public"."weekly_role_rates" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."weekly_role_rates" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."weekly_roster_snapshots" TO "anon";
GRANT ALL ON TABLE "public"."weekly_roster_snapshots" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."weekly_roster_snapshots" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."weeks" TO "anon";
GRANT ALL ON TABLE "public"."weeks" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."weeks" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";







