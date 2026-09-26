-- Run after delete-setup-league.sql. Existing Auth UUIDs and the original
-- league are unchanged. This migration is safe to rerun.
begin;

-- Existing managers already have a league identity. Mark their backfilled
-- profile as confirmed so invitations are not blocked by an old flag.
-- Newly registered people without memberships still complete onboarding.
update public.profiles profile
set onboarding_completed = true
where not profile.onboarding_completed
  and exists (select 1 from public.league_members member
    where member.user_id = profile.user_id and member.status = 'active');

-- Serialize membership changes for the same account, including invitations
-- accepted in two different leagues at nearly the same time.
create or replace function public.check_user_league_membership_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
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
drop trigger if exists check_user_league_membership_limit on public.league_members;
create trigger check_user_league_membership_limit
before insert or update of user_id, status on public.league_members
for each row execute function public.check_user_league_membership_limit();
revoke all on function public.check_user_league_membership_limit() from public, anon, authenticated;

create or replace function public.create_fantasy_league(p_name text, p_roster_size integer default 11)
returns uuid language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.create_fantasy_league(text,integer) from public, anon;
grant execute on function public.create_fantasy_league(text,integer) to authenticated;

-- Typed confirmation happens in the website. The database still requires
-- ownership and protects the original league from direct RPC calls.
create or replace function public.delete_fantasy_league(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.delete_fantasy_league(uuid) from public, anon;
grant execute on function public.delete_fantasy_league(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
