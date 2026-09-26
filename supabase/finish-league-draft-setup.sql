-- Run after activate-multi-league-workspaces.sql. Safe to rerun.
begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'leagues'
      and column_name = 'roster_size_overridden') then
    alter table public.leagues add column roster_size_overridden boolean not null default false;
    -- Earlier setup leagues defaulted to 11. Preserve distinguishable manual sizes.
    update public.leagues set roster_size_overridden = true
    where status = 'setup' and roster_size <> 11;
  end if;
end;
$$;

create or replace function public.suggest_league_roster_size(p_member_count integer)
returns integer language sql stable security definer set search_path = '' as $$
  select greatest(1, least(
    case when p_member_count >= 6 then 8
         when p_member_count = 5 then 8
         when p_member_count = 4 then 10
         else 12 end,
    (select count(*)::integer from public.cast_members) / greatest(3, p_member_count)
  ));
$$;
revoke all on function public.suggest_league_roster_size(integer) from public, anon, authenticated;

create or replace function public.check_league_membership_capacity()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_member_count integer; v_roster_size integer; v_manual boolean;
begin
  if new.status = 'active' and new.league_id <> public.default_fantasy_league_id() then
    if tg_op = 'UPDATE' then
      if old.status = 'active' then return new; end if;
    end if;
    perform 1 from public.leagues where id = new.league_id for update;
    select count(*) into v_member_count from public.league_members
      where league_id = new.league_id and status = 'active';
    if v_member_count >= 6 then
      raise exception 'This league is full (six managers maximum).';
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
drop trigger if exists check_league_membership_capacity on public.league_members;
create trigger check_league_membership_capacity
before insert or update of status on public.league_members
for each row execute function public.check_league_membership_capacity();

create or replace function public.refresh_automatic_roster_size()
returns trigger language plpgsql security definer set search_path = '' as $$
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
drop trigger if exists refresh_automatic_roster_size on public.league_members;
create trigger refresh_automatic_roster_size
after insert or delete or update of status on public.league_members
for each row execute function public.refresh_automatic_roster_size();

update public.leagues league
set roster_size = public.suggest_league_roster_size(
      (select count(*)::integer from public.league_members member
       where member.league_id = league.id and member.status = 'active')),
    updated_at = now()
where league.status = 'setup' and league.id <> public.default_fantasy_league_id()
  and not league.roster_size_overridden;

create or replace function public.update_league_workspace(
  p_league_id uuid, p_name text, p_roster_size integer, p_auto_roster boolean
)
returns void language plpgsql security definer set search_path = '' as $$
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

-- Preserve the older three-argument call for a site version cached during rollout.
create or replace function public.update_league_workspace(
  p_league_id uuid, p_name text, p_roster_size integer
)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.update_league_workspace(p_league_id, p_name, p_roster_size, null::boolean);
end;
$$;

create or replace function public.start_league_draft(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues; v_team_count integer;
begin
  if not public.is_league_owner(p_league_id) then raise exception 'League owner access required.'; end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.status <> 'setup' then raise exception 'The draft has already started.'; end if;
  select count(*) into v_team_count from public.league_members
  where league_id = p_league_id and status = 'active';
  if v_team_count not between 3 and 6 then
    raise exception 'Invite 3 to 6 managers before starting the draft.';
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
  update public.leagues set status = 'drafting', draft_started_at = now(), updated_at = now()
  where id = p_league_id;
end;
$$;

-- The last draft pick makes the league active. Backfill every completed show
-- with the original draft teams, not later trades or free-agent swaps.
create or replace function public.backfill_drafted_league_weeks(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.league_weekly_roster_snapshots
    (league_id, week_id, cast_member_id, fantasy_team_id,
     cast_member_name, cast_role, appearance_points, manager_name, team_name)
  select p_league_id, week.id, cast_member.id, pick.fantasy_team_id,
    cast_member.name,
    case when cast_member.role = 'Eliminated Star' and week.number <= eliminated_week.number then 'Star'
         when cast_member.role = 'Eliminated Pro' and week.number <= eliminated_week.number then 'Pro'
         else cast_member.role end,
    case when cast_member.role = 'Surprise' then cast_member.custom_appearance_points
         else (select rate.appearance_points from public.league_role_rates rate
           join public.roles role on role.id = rate.role_id
           where rate.league_id = p_league_id and role.name =
             case when cast_member.is_hough then 'Hough'
                  when cast_member.role = 'Eliminated Star' and week.number <= eliminated_week.number then 'Star'
                  when cast_member.role = 'Eliminated Pro' and week.number <= eliminated_week.number then 'Pro'
                  else cast_member.role end) end,
    team.manager_name, team.team_name
  from public.weeks week
  cross join public.cast_members cast_member
  left join public.weeks eliminated_week on eliminated_week.id = cast_member.eliminated_week_id
  left join public.league_draft_picks pick on pick.league_id = p_league_id
    and pick.cast_member_id = cast_member.id
  left join public.fantasy_teams team on team.id = pick.fantasy_team_id
  where week.is_complete
  on conflict (league_id, week_id, cast_member_id) do nothing;
end;
$$;
revoke all on function public.backfill_drafted_league_weeks(uuid) from public, anon, authenticated;

create or replace function public.activate_drafted_league_snapshots()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'active' and old.status = 'drafting'
    and new.id <> public.default_fantasy_league_id() then
    update public.leagues set scoring_starts_after_week = 0 where id = new.id;
    perform public.backfill_drafted_league_weeks(new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists activate_drafted_league_snapshots on public.leagues;
create trigger activate_drafted_league_snapshots
after update of status on public.leagues
for each row execute function public.activate_drafted_league_snapshots();

-- Repair completed drafts created before this migration, while preserving
-- any snapshots already taken for later airings.
update public.leagues league set scoring_starts_after_week = 0
where league.id <> public.default_fantasy_league_id() and league.status = 'active'
  and exists (select 1 from public.league_draft_order draft where draft.league_id = league.id)
  and (select count(*) from public.league_draft_picks pick where pick.league_id = league.id)
      = league.roster_size * (select count(*) from public.league_draft_order draft
                              where draft.league_id = league.id);
do $$
declare v_league_id uuid;
begin
  for v_league_id in select league.id from public.leagues league
    where league.id <> public.default_fantasy_league_id() and league.status = 'active'
      and exists (select 1 from public.league_draft_order draft where draft.league_id = league.id)
      and (select count(*) from public.league_draft_picks pick where pick.league_id = league.id)
          = league.roster_size * (select count(*) from public.league_draft_order draft
                                  where draft.league_id = league.id)
  loop
    perform public.backfill_drafted_league_weeks(v_league_id);
  end loop;
end;
$$;

revoke all on function public.check_league_membership_capacity(),
  public.refresh_automatic_roster_size(), public.activate_drafted_league_snapshots()
  from public, anon, authenticated;
revoke all on function public.update_league_workspace(uuid,text,integer),
  public.update_league_workspace(uuid,text,integer,boolean),
  public.start_league_draft(uuid) from public, anon;
grant execute on function public.update_league_workspace(uuid,text,integer),
  public.update_league_workspace(uuid,text,integer,boolean),
  public.start_league_draft(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
