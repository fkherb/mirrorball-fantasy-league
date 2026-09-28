-- Run after secondary-league-roster-balance-and-airing-lock.sql.
-- New/setting-up leagues have 3–5 managers and fixed roster presets.
-- The database membership trigger caps each secondary league at five active managers.
begin;

create or replace function public.suggest_league_roster_size(p_member_count integer)
returns integer language sql stable security definer set search_path = '' as $$
  select case when p_member_count >= 5 then 8
              when p_member_count = 4 then 10
              else 12 end;
$$;
revoke all on function public.suggest_league_roster_size(integer)
  from public, anon, authenticated;

create or replace function public.check_league_membership_capacity()
returns trigger language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.check_league_membership_capacity()
  from public, anon, authenticated;

-- Set each setup league to the current preset without changing started rosters.
update public.leagues league
set roster_size = public.suggest_league_roster_size(
      (select count(*)::integer from public.league_members member
       where member.league_id = league.id and member.status = 'active')),
    roster_size_overridden = false, updated_at = now()
where league.status = 'setup'
  and league.id <> public.default_fantasy_league_id()
  and (select count(*) from public.league_members member
       where member.league_id = league.id and member.status = 'active') <= 5;

-- The old capacity check counted one extra active pick per manager without
-- checking that those extra Pros/Stars actually exist league-wide.
create or replace function public.check_balanced_draft_capacity()
returns trigger language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.check_balanced_draft_capacity()
  from public, anon, authenticated;

-- A Flex pick may use only a Pro or Star left over after reserving one
-- standard slot for every manager who has not filled that role yet.
create or replace function public.league_unreserved_active_role_count(
  p_league_id uuid, p_role text
)
returns integer language sql volatile security definer set search_path = '' as $$
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
revoke all on function public.league_unreserved_active_role_count(uuid,text)
  from public, anon, authenticated;

create or replace function public.league_pick_is_eligible(
  p_league_id uuid, p_team_id uuid, p_cast_member_id uuid
)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
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
revoke all on function public.league_pick_is_eligible(uuid,uuid,uuid)
  from public, anon, authenticated;

create or replace function public.enforce_league_draft_role_reserves()
returns trigger language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.enforce_league_draft_role_reserves()
  from public, anon, authenticated;
drop trigger if exists enforce_league_draft_role_reserves on public.league_roster_assignments;
create trigger enforce_league_draft_role_reserves
after insert or update of fantasy_team_id on public.league_roster_assignments
for each row execute function public.enforce_league_draft_role_reserves();

-- Reject a trade offer or counteroffer up front if either recipient would
-- exceed today's active-role cap. Acceptance is independently checked by the
-- existing roster-assignment trigger, so later eliminations cannot bypass it.
create or replace function public.check_secondary_league_trade_role_limits()
returns trigger language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.check_secondary_league_trade_role_limits()
  from public, anon, authenticated;
drop trigger if exists check_secondary_league_trade_role_limits on public.league_trade_offers;
create trigger check_secondary_league_trade_role_limits
before insert or update of initiator_cast_member_id, counterparty_cast_member_id
on public.league_trade_offers
for each row execute function public.check_secondary_league_trade_role_limits();

commit;
notify pgrst, 'reload schema';
