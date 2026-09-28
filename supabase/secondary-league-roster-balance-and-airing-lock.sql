-- Run after draft-readiness-and-untimed-mode.sql and add-week-airing-dates.sql.
-- Applies only to leagues created after the original/default league.
-- Existing completed-week snapshots are deliberately left unchanged.
begin;

alter table public.cast_members add column if not exists surprise_base_role text;
alter table public.cast_members drop constraint if exists cast_members_surprise_base_role_check;
alter table public.cast_members add constraint cast_members_surprise_base_role_check
  check (surprise_base_role is null or surprise_base_role in
    ('Eliminated Pro', 'Eliminated Star', 'Troupe', 'DWTS Next Pro', 'Judges + Hosts'));

-- Existing surprise entries keep their prior custom points until their normal
-- role is classified. A numeric rate alone cannot distinguish every role.

-- Keep the original league's custom surprise points untouched. New leagues use
-- the selected base role's own rate plus two at each weekly snapshot.
create or replace function public.save_cast_member_profile_with_surprise_role(
  p_cast_member_id uuid, p_name text, p_role text, p_image_path text,
  p_image_position integer, p_custom_appearance_points integer,
  p_role_detail text, p_is_hough boolean, p_partner_id uuid,
  p_partnership_name text, p_bio text, p_career_highlights text,
  p_mirrorball_wins integer, p_surprise_base_role text
)
returns uuid language plpgsql security invoker set search_path = '' as $$
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
revoke all on function public.save_cast_member_profile_with_surprise_role(
  uuid,text,text,text,integer,integer,text,boolean,uuid,text,text,text,integer,text)
  from public, anon;
grant execute on function public.save_cast_member_profile_with_surprise_role(
  uuid,text,text,text,integer,integer,text,boolean,uuid,text,text,text,integer,text)
  to authenticated;

create or replace function public.league_cast_category(p_role text)
returns text language sql immutable set search_path = '' as $$
  select case when p_role in ('Pro', 'Star') then p_role else 'Bonus' end;
$$;

create or replace function public.league_category_limit(p_league_id uuid, p_role text)
returns integer language sql stable security definer set search_path = '' as $$
  select case when p_role in ('Pro', 'Star') then
    (select count(*)::integer from public.cast_members where role = p_role)
    / greatest(1, (select count(*)::integer from public.league_members
      where league_id = p_league_id and status = 'active'))
  else null end;
$$;

create or replace function public.league_flex_allowance(p_league_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
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

create or replace function public.league_bonus_draft_limit(p_league_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select greatest(0, league.roster_size
    - public.league_category_limit(league.id, 'Pro')
    - public.league_category_limit(league.id, 'Star')
    - public.league_flex_allowance(league.id))
  from public.leagues league where league.id = p_league_id;
$$;

create or replace function public.league_pick_is_eligible(
  p_league_id uuid, p_team_id uuid, p_cast_member_id uuid
)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case when public.league_cast_category(c.role) = 'Bonus' then
      (select count(*) from public.league_roster_assignments a
       join public.cast_members owned on owned.id = a.cast_member_id
       where a.league_id = p_league_id and a.fantasy_team_id = p_team_id
         and owned.role not in ('Pro', 'Star'))
       < public.league_bonus_draft_limit(p_league_id)
    else
      (select count(*) from public.league_roster_assignments a
       join public.cast_members owned on owned.id = a.cast_member_id
       where a.league_id = p_league_id and a.fantasy_team_id = p_team_id
         and owned.role = c.role) < public.league_category_limit(p_league_id, c.role)
        + public.league_flex_allowance(p_league_id)
      and (select count(*) from public.league_roster_assignments a
       join public.cast_members owned on owned.id = a.cast_member_id
       where a.league_id = p_league_id and a.fantasy_team_id = p_team_id
         and owned.role in ('Pro', 'Star'))
        < public.league_category_limit(p_league_id, 'Pro')
          + public.league_category_limit(p_league_id, 'Star')
          + public.league_flex_allowance(p_league_id)
    end
    from public.cast_members c where c.id = p_cast_member_id
  ), false);
$$;
revoke all on function public.league_category_limit(uuid,text),
  public.league_flex_allowance(uuid), public.league_bonus_draft_limit(uuid),
  public.league_pick_is_eligible(uuid,uuid,uuid) from public, anon, authenticated;

create or replace function public.suggest_league_roster_size(p_member_count integer)
returns integer language sql stable security definer set search_path = '' as $$
  select greatest(1, least(
    case when p_member_count >= 6 then 7
         when p_member_count = 5 then 8
         when p_member_count = 4 then 10
         else 12 end,
    (select count(*)::integer from public.cast_members) / greatest(3, p_member_count)
  ));
$$;
revoke all on function public.suggest_league_roster_size(integer) from public, anon, authenticated;

-- New leagues always use the preset size; old active/drafting rosters are not resized.
create or replace function public.enforce_preset_league_roster_size()
returns trigger language plpgsql set search_path = '' as $$
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
drop trigger if exists enforce_preset_league_roster_size on public.leagues;
create trigger enforce_preset_league_roster_size
before insert or update on public.leagues
for each row execute function public.enforce_preset_league_roster_size();
update public.leagues set roster_size_overridden = false
where id <> public.default_fantasy_league_id() and status = 'setup';

-- A preset cannot start a draft if the current Pro/Star caps leave fewer
-- eligible picks than roster spots. This avoids an unwinnable timed draft.
create or replace function public.check_balanced_draft_capacity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_managers integer; v_pros integer; v_stars integer; v_bonus integer;
begin
  if new.id = public.default_fantasy_league_id()
     or new.status <> 'drafting' or old.status = 'drafting' then return new; end if;
  select count(*) into v_managers from public.league_members
    where league_id = new.id and status = 'active';
  if v_managers < 1 then return new; end if;
  select count(*) filter (where role = 'Pro'),
    count(*) filter (where role = 'Star'),
    count(*) filter (where role not in ('Pro', 'Star'))
    into v_pros, v_stars, v_bonus from public.cast_members;
  if (v_pros / v_managers + v_stars / v_managers + v_bonus / v_managers + 1) < new.roster_size then
    raise exception 'The %–cast preset cannot be filled under the current Pro/Star limits. Wait for more Bonus cast before starting this draft.', new.roster_size;
  end if;
  return new;
end;
$$;
drop trigger if exists check_balanced_draft_capacity on public.leagues;
create trigger check_balanced_draft_capacity
before update of status on public.leagues
for each row execute function public.check_balanced_draft_capacity();

-- A single immutable snapshot function is used both on show day and when a
-- week is completed. The original league continues using its existing path.
create or replace function public.capture_secondary_league_week_snapshot(
  p_league_id uuid, p_week_id uuid
)
returns void language plpgsql security definer set search_path = '' as $$
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

-- The existing draft-activation trigger calls this function. Route its
-- completed-week backfill through the same new-league rate calculation so
-- surprise bonuses and historical elimination roles agree with future weeks.
create or replace function public.backfill_drafted_league_weeks(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_week record;
begin
  for v_week in select id from public.weeks where is_complete order by number loop
    perform public.capture_secondary_league_week_snapshot(p_league_id, v_week.id);
  end loop;
end;
$$;
revoke all on function public.backfill_drafted_league_weeks(uuid) from public, anon, authenticated;

create or replace function public.capture_due_secondary_league_snapshots(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_week record; v_today date := (clock_timestamp() at time zone 'America/New_York')::date;
begin
  perform 1 from public.leagues where id = p_league_id for update;
  for v_week in select week.id from public.weeks week
    join public.leagues league on league.id = p_league_id
    where league.status = 'active' and week.number > league.scoring_starts_after_week
      and week.air_date is not null and week.air_date <= v_today
  loop
    perform public.capture_secondary_league_week_snapshot(p_league_id, v_week.id);
  end loop;
end;
$$;

create or replace function public.refresh_my_league_snapshots(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_league_member(p_league_id) then raise exception 'League membership required.'; end if;
  perform public.capture_due_secondary_league_snapshots(p_league_id);
end;
$$;
revoke all on function public.refresh_my_league_snapshots(uuid) from public, anon;
grant execute on function public.refresh_my_league_snapshots(uuid) to authenticated;
revoke all on function public.capture_secondary_league_week_snapshot(uuid,uuid),
  public.capture_due_secondary_league_snapshots(uuid) from public, anon, authenticated;

create or replace function public.snapshot_other_leagues_on_week_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
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

-- The guard runs before every active-league roster mutation. It preserves the
-- airing-date roster before a later swap and blocks changes on either show date.
create or replace function public.guard_secondary_league_roster_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid;
  v_status text; v_today date := (clock_timestamp() at time zone 'America/New_York')::date;
begin
  v_league_id := case when tg_op = 'DELETE' then old.league_id else new.league_id end;
  if v_league_id = public.default_fantasy_league_id() then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  select status into v_status from public.leagues where id = v_league_id for update;
  if v_status = 'active' then
    perform public.capture_due_secondary_league_snapshots(v_league_id);
    if exists (select 1 from public.weeks
      where air_date = v_today or second_air_date = v_today) then
      raise exception 'Rosters are locked on show days (Eastern time). Try again tomorrow.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
drop trigger if exists guard_secondary_league_roster_change on public.league_roster_assignments;
create trigger guard_secondary_league_roster_change
before insert or update or delete on public.league_roster_assignments
for each row execute function public.guard_secondary_league_roster_change();

-- Bonus members never use a Pro/Star slot. Existing over-limit rosters remain
-- intact after elimination; only incoming assignments are tested.
create or replace function public.enforce_secondary_league_category_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
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
drop trigger if exists enforce_secondary_league_category_limit on public.league_roster_assignments;
create trigger enforce_secondary_league_category_limit
after insert or update of fantasy_team_id on public.league_roster_assignments
for each row execute function public.enforce_secondary_league_category_limit();

-- Timed automatic picks must choose from the same eligible pool as manual picks.
create or replace function public.advance_league_draft_clock(p_league_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.advance_league_draft_clock(uuid) from public, anon;
grant execute on function public.advance_league_draft_clock(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
