-- Run once after allow-drafting-during-airing.sql and ordered-auto-draft.sql.
-- New drafts cannot begin after an incomplete week's airing starts. Drafts
-- already in progress keep the cast roles they saw at their own start.
begin;

alter table public.leagues
  add column if not exists draft_cast_roles jsonb not null default '{}'::jsonb;

create or replace function public.capture_league_draft_cast_roles()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'setup' and new.status = 'drafting'
     and new.id <> public.default_fantasy_league_id() then
    new.draft_cast_roles := (select coalesce(jsonb_object_agg(c.id::text, c.role), '{}'::jsonb)
      from public.cast_members c);
  end if;
  return new;
end;
$$;
drop trigger if exists aaa_capture_league_draft_cast_roles on public.leagues;
create trigger aaa_capture_league_draft_cast_roles
before update of status on public.leagues for each row
execute function public.capture_league_draft_cast_roles();

-- An already-running draft cannot be reconstructed exactly if its cast changed
-- before this migration; freeze its current pool rather than leave it unfrozen.
update public.leagues l
set draft_cast_roles = (select coalesce(jsonb_object_agg(c.id::text, c.role), '{}'::jsonb)
  from public.cast_members c)
where l.status = 'drafting' and l.draft_cast_roles = '{}'::jsonb;

create or replace function public.league_draft_role(p_league_id uuid, p_cast_member_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when l.status = 'drafting'
    then l.draft_cast_roles ->> p_cast_member_id::text else c.role end
  from public.leagues l cross join public.cast_members c
  where l.id = p_league_id and c.id = p_cast_member_id;
$$;
revoke all on function public.league_draft_role(uuid,uuid)
  from public, anon, authenticated;

create or replace function public.get_league_draft_cast_roles(p_league_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_roles jsonb;
begin
  if auth.uid() is null or not public.is_league_member(p_league_id) then
    raise exception 'League membership required.';
  end if;
  select draft_cast_roles into v_roles from public.leagues where id = p_league_id;
  return coalesce(v_roles, '{}'::jsonb);
end;
$$;
revoke all on function public.get_league_draft_cast_roles(uuid) from public, anon;
grant execute on function public.get_league_draft_cast_roles(uuid) to authenticated;

create or replace function public.league_category_limit(p_league_id uuid, p_role text)
returns integer language sql stable security definer set search_path = '' as $$
  select case when p_role in ('Pro', 'Star') then
    (select count(*)::integer from public.cast_members c
      where public.league_draft_role(p_league_id, c.id) = p_role)
    / greatest(1, (select count(*)::integer from public.league_members m
      where m.league_id = p_league_id and m.status = 'active'))
  else null end;
$$;

create or replace function public.league_flex_allowance(p_league_id uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select case when l.status in ('setup', 'drafting')
    and l.roster_size > public.league_category_limit(l.id, 'Pro')
      + public.league_category_limit(l.id, 'Star')
      + (select count(*)::integer from public.cast_members c
         where public.league_draft_role(l.id, c.id) not in ('Pro', 'Star'))
        / greatest(1, (select count(*)::integer from public.league_members m
          where m.league_id = l.id and m.status = 'active'))
    then 1 else 0 end
  from public.leagues l where l.id = p_league_id;
$$;

create or replace function public.league_unreserved_active_role_count(
  p_league_id uuid, p_role text
) returns integer language sql volatile security definer set search_path = '' as $$
  select (select count(*)::integer from public.cast_members c
      where public.league_draft_role(p_league_id, c.id) = p_role)
    - (select count(*)::integer from public.league_roster_assignments a
       where a.league_id = p_league_id
         and public.league_draft_role(p_league_id, a.cast_member_id) = p_role)
    - coalesce((select sum(greatest(0,
        public.league_category_limit(p_league_id, p_role) -
        (select count(*)::integer from public.league_roster_assignments a
         where a.league_id = p_league_id and a.fantasy_team_id = m.fantasy_team_id
           and public.league_draft_role(p_league_id, a.cast_member_id) = p_role)))::integer
      from public.league_members m
      where m.league_id = p_league_id and m.status = 'active'), 0);
$$;

create or replace function public.league_pick_is_eligible(
  p_league_id uuid, p_team_id uuid, p_cast_member_id uuid
) returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare v_role text; v_team_role integer; v_team_active integer; v_team_bonus integer;
  v_limit integer; v_flex integer;
begin
  v_role := public.league_draft_role(p_league_id, p_cast_member_id);
  if v_role is null then return false; end if;
  if v_role not in ('Pro', 'Star') then
    select count(*) into v_team_bonus from public.league_roster_assignments a
      where a.league_id = p_league_id and a.fantasy_team_id = p_team_id
        and public.league_draft_role(p_league_id, a.cast_member_id) not in ('Pro', 'Star');
    return v_team_bonus < public.league_bonus_draft_limit(p_league_id);
  end if;
  select count(*) filter (where public.league_draft_role(p_league_id, a.cast_member_id) = v_role),
    count(*) filter (where public.league_draft_role(p_league_id, a.cast_member_id) in ('Pro', 'Star'))
    into v_team_role, v_team_active
  from public.league_roster_assignments a
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

create or replace function public.enforce_league_draft_role_reserves()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_role text; v_team_role_count integer;
begin
  if new.league_id = public.default_fantasy_league_id()
     or (select status from public.leagues where id = new.league_id) <> 'drafting' then
    return new;
  end if;
  v_role := public.league_draft_role(new.league_id, new.cast_member_id);
  if v_role not in ('Pro', 'Star') then return new; end if;
  select count(*) into v_team_role_count from public.league_roster_assignments a
    where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
      and public.league_draft_role(new.league_id, a.cast_member_id) = v_role;
  if v_team_role_count > public.league_category_limit(new.league_id, v_role)
     and public.league_unreserved_active_role_count(new.league_id, v_role) < 0 then
    raise exception 'That % is reserved for another manager’s unfilled draft slot.', lower(v_role);
  end if;
  return new;
end;
$$;

create or replace function public.enforce_secondary_league_category_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_status text; v_role text; v_category text;
  v_total integer; v_active_total integer; v_limit integer; v_flex integer;
begin
  if new.league_id = public.default_fantasy_league_id() then return new; end if;
  select status into v_status from public.leagues where id = new.league_id;
  if v_status not in ('drafting', 'active') then return new; end if;
  if tg_op = 'UPDATE' and new.fantasy_team_id is not distinct from old.fantasy_team_id then return new; end if;
  v_role := public.league_draft_role(new.league_id, new.cast_member_id);
  v_category := public.league_cast_category(v_role);
  if v_category = 'Bonus' then
    if v_status = 'drafting' then
      select count(*) into v_total from public.league_roster_assignments a
        where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
          and public.league_draft_role(new.league_id, a.cast_member_id) not in ('Pro', 'Star');
      if v_total > public.league_bonus_draft_limit(new.league_id) then
        raise exception 'This draft team has filled its Bonus spots.';
      end if;
    end if;
    return new;
  end if;
  select count(*) into v_total from public.league_roster_assignments a
    where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
      and public.league_draft_role(new.league_id, a.cast_member_id) = v_role;
  v_limit := public.league_category_limit(new.league_id, v_role);
  v_flex := case when v_status = 'drafting' then public.league_flex_allowance(new.league_id) else 0 end;
  select count(*) into v_active_total from public.league_roster_assignments a
    where a.league_id = new.league_id and a.fantasy_team_id = new.fantasy_team_id
      and public.league_draft_role(new.league_id, a.cast_member_id) in ('Pro', 'Star');
  if v_total > v_limit + v_flex
     or v_active_total > public.league_category_limit(new.league_id, 'Pro')
       + public.league_category_limit(new.league_id, 'Star') + v_flex then
    raise exception 'This team may add no more active % cast (limit %, current %).',
      lower(v_role), v_limit + v_flex, v_total;
  end if;
  return new;
end;
$$;

create or replace function public.choose_ordered_random_draft_cast(
  p_league_id uuid, p_team_id uuid
) returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare v_cast_id uuid; v_pro integer; v_star integer; v_bonus integer;
begin
  select count(*) filter (where public.league_draft_role(p_league_id, a.cast_member_id) = 'Pro'),
    count(*) filter (where public.league_draft_role(p_league_id, a.cast_member_id) = 'Star'),
    count(*) filter (where public.league_draft_role(p_league_id, a.cast_member_id) not in ('Pro', 'Star'))
    into v_pro, v_star, v_bonus
  from public.league_roster_assignments a
  where a.league_id = p_league_id and a.fantasy_team_id = p_team_id;
  select c.id into v_cast_id from public.cast_members c
  where not exists (select 1 from public.league_roster_assignments a
    where a.league_id = p_league_id and a.cast_member_id = c.id)
    and public.league_pick_is_eligible(p_league_id, p_team_id, c.id)
  order by case
    when public.league_draft_role(p_league_id, c.id) = 'Pro'
      and v_pro < public.league_category_limit(p_league_id, 'Pro') then 0
    when public.league_draft_role(p_league_id, c.id) = 'Star'
      and v_star < public.league_category_limit(p_league_id, 'Star') then 1
    when public.league_draft_role(p_league_id, c.id) not in ('Pro', 'Star')
      and v_bonus < public.league_bonus_draft_limit(p_league_id) then 2
    else 3
  end, random() limit 1;
  return v_cast_id;
end;
$$;

-- The old draft-airing function remains permissive for picks and the clock.
-- This separate guard concerns new drafts only, beginning at actual airtime.
create or replace function public.guard_league_draft_start_airing_window()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'setup' and new.status = 'drafting'
    and new.id <> public.default_fantasy_league_id()
    and exists (
      select 1 from public.weeks w
      cross join lateral (values
        (w.air_date, w.air_start_time),
        (w.second_air_date, coalesce(w.second_air_start_time, w.air_start_time))
      ) as airing(day, starts)
      where not w.is_complete and airing.day is not null
        and clock_timestamp() >= ((airing.day + airing.starts) at time zone 'America/New_York')
    ) then
    raise exception 'A new draft cannot start after this week’s airing begins. Wait until the week is marked complete.';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_league_draft_start_airing_window on public.leagues;
create trigger guard_league_draft_start_airing_window
before update of status on public.leagues for each row
execute function public.guard_league_draft_start_airing_window();

commit;
notify pgrst, 'reload schema';
