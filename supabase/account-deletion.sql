-- Run after the shared-league and snapshot-name migrations. Deploy the
-- delete-account Edge Function after this SQL. Safe to rerun.
begin;

alter table public.fantasy_teams
  add column if not exists orphaned_by_account_deletion boolean not null default false;

create or replace function public.guard_orphaned_team_flag()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if old.orphaned_by_account_deletion
       and coalesce(current_setting('mirrorball.deleting_account', true), '') <> 'on'
       and not (coalesce(current_setting('mirrorball.renaming_orphan', true), '') = 'on'
         and new.id = old.id and new.league_id = old.league_id
         and new.manager_name = old.manager_name
         and new.orphaned_by_account_deletion = old.orphaned_by_account_deletion) then
      raise exception 'This unmanaged team can only be renamed by its commissioner.';
    end if;
    if new.orphaned_by_account_deletion is distinct from old.orphaned_by_account_deletion
       and coalesce(current_setting('mirrorball.deleting_account', true), '') <> 'on' then
      raise exception 'Only account deletion may mark an unmanaged team.';
    end if;
  elsif new.orphaned_by_account_deletion
      and coalesce(current_setting('mirrorball.deleting_account', true), '') <> 'on' then
    raise exception 'Only account deletion may mark an unmanaged team.';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_orphaned_team_flag() from public, anon, authenticated;
drop trigger if exists guard_orphaned_team_flag on public.fantasy_teams;
create trigger guard_orphaned_team_flag
  before insert or update on public.fantasy_teams
  for each row execute function public.guard_orphaned_team_flag();

-- Draft history stays useful to league members without retaining the deleted
-- account's identity. The original FK would otherwise block Auth deletion.
alter table public.league_draft_picks alter column picked_by drop not null;
alter table public.league_draft_picks drop constraint if exists league_draft_picks_picked_by_fkey;
alter table public.league_draft_picks add constraint league_draft_picks_picked_by_fkey
  foreign key (picked_by) references public.profiles(user_id) on delete set null;

create or replace function public.account_deletion_blockers()
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare v_blockers text[] := '{}'; v_league record;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if exists (select 1 from public.platform_admins where user_id = auth.uid())
    and (select count(*) from public.platform_admins) <= 1 then
    v_blockers := array_append(v_blockers,
      'The last platform owner cannot delete their account. Assign another platform owner first.');
  end if;
  for v_league in select league.name from public.league_members member
    join public.leagues league on league.id = member.league_id
    where member.user_id = auth.uid() and member.status = 'active' and member.role = 'owner'
      and not exists (select 1 from public.league_members successor
        where successor.league_id = member.league_id and successor.user_id <> auth.uid()
          and successor.status = 'active')
  loop
    v_blockers := array_append(v_blockers,
      'Delete the league "' || v_league.name || '" first; it has no other manager to take over.');
  end loop;
  return v_blockers;
end;
$$;
revoke all on function public.account_deletion_blockers() from public, anon;
grant execute on function public.account_deletion_blockers() to authenticated;

-- This runs in the same transaction as the Auth deletion. A failed cleanup
-- rolls the Auth deletion back instead of leaving a half-deleted account.
create or replace function public.prepare_account_deletion()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_league record; v_successor uuid;
begin
  if exists (select 1 from public.platform_admins where user_id = old.id)
    and (select count(*) from public.platform_admins) <= 1 then
    raise exception 'The last platform owner cannot delete their account.';
  end if;
  perform set_config('mirrorball.deleting_account', 'on', true);

  -- Transfer commissionership to the longest-serving active manager.
  for v_league in select member.league_id from public.league_members member
    where member.user_id = old.id and member.status = 'active' and member.role = 'owner'
  loop
    perform 1 from public.leagues where id = v_league.league_id for update;
    select successor.user_id into v_successor from public.league_members successor
      where successor.league_id = v_league.league_id and successor.user_id <> old.id
        and successor.status = 'active'
      order by successor.joined_at, successor.user_id limit 1;
    if v_successor is null then
      raise exception 'Delete leagues with no other manager before deleting your account.';
    end if;
    update public.league_members set role = 'member'
      where league_id = v_league.league_id and user_id = old.id;
    update public.league_members set role = 'owner'
      where league_id = v_league.league_id and user_id = v_successor;
    update public.leagues set created_by = v_successor
      where id = v_league.league_id and created_by = old.id;
  end loop;

  delete from public.league_invites where inviter_id = old.id or invitee_id = old.id;
  delete from public.league_invite_links where created_by = old.id;
  update public.league_draft_picks set picked_by = null where picked_by = old.id;
  update public.leagues set created_by = null where created_by = old.id;

  update public.fantasy_teams team
    set manager_name = 'Deleted account', team_name = 'Former team',
      orphaned_by_account_deletion = true
    from public.league_members member
    where member.user_id = old.id and member.fantasy_team_id = team.id;
  update public.weekly_roster_snapshots snapshot set manager_name = 'Deleted account'
    from public.fantasy_teams team
    where snapshot.fantasy_team_id = team.id and team.orphaned_by_account_deletion;
  update public.league_weekly_roster_snapshots snapshot set manager_name = 'Deleted account'
    from public.fantasy_teams team
    where snapshot.fantasy_team_id = team.id and team.orphaned_by_account_deletion;
  update public.trade_history history set initiator_team_name = 'Former team'
    from public.fantasy_teams team
    join public.league_members member on member.fantasy_team_id = team.id
    where member.user_id = old.id and history.initiator_team_id = team.id;
  update public.trade_history history set counterparty_team_name = 'Former team'
    from public.fantasy_teams team
    join public.league_members member on member.fantasy_team_id = team.id
    where member.user_id = old.id and history.counterparty_team_id = team.id;

  -- The orphan has no manager who could accept an existing offer. Cancel
  -- these offers; future offers to it are accepted immediately below.
  delete from public.league_trade_offers offer using public.fantasy_teams team
    join public.league_members member on member.fantasy_team_id = team.id
    where member.user_id = old.id and team.orphaned_by_account_deletion
      and team.id in (offer.initiator_team_id, offer.counterparty_team_id);
  delete from public.trade_offers offer using public.fantasy_teams team
    join public.league_members member on member.fantasy_team_id = team.id
    where member.user_id = old.id and team.orphaned_by_account_deletion
      and team.id in (offer.initiator_team_id, offer.counterparty_team_id);
  delete from public.league_members where user_id = old.id;
  return old;
end;
$$;
revoke all on function public.prepare_account_deletion() from public, anon, authenticated;
drop trigger if exists prepare_account_deletion on auth.users;
create trigger prepare_account_deletion before delete on auth.users
  for each row execute function public.prepare_account_deletion();

create or replace function public.rename_orphaned_team(p_league_id uuid, p_team_id uuid, p_team_name text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_league_owner(p_league_id) then raise exception 'Commissioner access required.'; end if;
  if length(trim(coalesce(p_team_name, ''))) not between 1 and 80 then
    raise exception 'Team name must be 1–80 characters.';
  end if;
  perform set_config('mirrorball.renaming_orphan', 'on', true);
  update public.fantasy_teams set team_name = trim(p_team_name)
    where id = p_team_id and league_id = p_league_id and orphaned_by_account_deletion;
  if not found then raise exception 'Only a deleted account’s team can be renamed here.'; end if;
end;
$$;
revoke all on function public.rename_orphaned_team(uuid,uuid,text) from public, anon;
grant execute on function public.rename_orphaned_team(uuid,uuid,text) to authenticated;

-- Preserve the existing request checks (rosters, active league, open offers,
-- and airing lock), then complete an offer to an unmanaged team atomically.
do $$ begin
  if to_regprocedure('public.request_league_trade_before_orphans(uuid,uuid,uuid)') is null then
    alter function public.request_league_trade(uuid,uuid,uuid)
      rename to request_league_trade_before_orphans;
  end if;
end $$;
revoke all on function public.request_league_trade_before_orphans(uuid,uuid,uuid)
  from public, anon, authenticated;

create or replace function public.accept_orphaned_team_trade(p_offer_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_offer public.league_trade_offers; v_other public.league_trade_offers;
begin
  select * into v_offer from public.league_trade_offers where id = p_offer_id for update;
  if v_offer.id is null then raise exception 'Trade offer is no longer available.'; end if;
  if not exists (select 1 from public.fantasy_teams team
      where team.id = v_offer.counterparty_team_id and team.orphaned_by_account_deletion)
    or exists (select 1 from public.league_members member
      where member.league_id = v_offer.league_id and member.fantasy_team_id = v_offer.counterparty_team_id
        and member.status = 'active') then
    raise exception 'This team is not unmanaged.';
  end if;
  if not exists (select 1 from public.league_members member
      where member.league_id = v_offer.league_id and member.fantasy_team_id = v_offer.initiator_team_id
        and member.user_id = auth.uid() and member.status = 'active') then
    raise exception 'Only the sending manager can initiate this trade.';
  end if;
  if public.league_trade_airing_locked() then raise exception 'Trades are paused during the airing window.'; end if;
  if not exists (select 1 from public.league_roster_assignments
      where league_id = v_offer.league_id and cast_member_id = v_offer.initiator_cast_member_id
        and fantasy_team_id = v_offer.initiator_team_id)
    or not exists (select 1 from public.league_roster_assignments
      where league_id = v_offer.league_id and cast_member_id = v_offer.counterparty_cast_member_id
        and fantasy_team_id = v_offer.counterparty_team_id) then
    raise exception 'The offer no longer matches the current rosters.';
  end if;
  update public.league_roster_assignments set fantasy_team_id = case
    when cast_member_id = v_offer.initiator_cast_member_id then v_offer.counterparty_team_id
    else v_offer.initiator_team_id end
    where league_id = v_offer.league_id
      and cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id);
  if v_offer.league_id = public.default_fantasy_league_id() then
    update public.cast_members set fantasy_team_id = case
      when id = v_offer.initiator_cast_member_id then v_offer.counterparty_team_id
      else v_offer.initiator_team_id end
      where id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id);
  end if;
  perform public.record_league_trade_event(v_offer, 'accepted', v_offer.initiator_team_id);
  delete from public.league_trade_offers where id = p_offer_id;
  for v_other in select * from public.league_trade_offers offer
    where offer.league_id = v_offer.league_id and
      (offer.initiator_cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id)
       or offer.counterparty_cast_member_id in (v_offer.initiator_cast_member_id, v_offer.counterparty_cast_member_id))
    for update
  loop
    perform public.record_league_trade_event(v_other, 'invalidated');
    delete from public.league_trade_offers where id = v_other.id;
  end loop;
end;
$$;
revoke all on function public.accept_orphaned_team_trade(uuid) from public, anon, authenticated;

create or replace function public.request_league_trade(
  p_league_id uuid, p_my_cast_member_id uuid, p_requested_cast_member_id uuid
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_offer_id uuid;
begin
  v_offer_id := public.request_league_trade_before_orphans(
    p_league_id, p_my_cast_member_id, p_requested_cast_member_id);
  if exists (select 1 from public.league_trade_offers offer
    join public.fantasy_teams team on team.id = offer.counterparty_team_id
    where offer.id = v_offer_id and team.orphaned_by_account_deletion) then
    perform public.accept_orphaned_team_trade(v_offer_id);
  end if;
  return v_offer_id;
end;
$$;
revoke all on function public.request_league_trade(uuid,uuid,uuid) from public, anon;
grant execute on function public.request_league_trade(uuid,uuid,uuid) to authenticated;

-- Team-only records are retained during the season and purged once the
-- season-finale week is complete and the airing trade lock has ended.
create or replace function public.cleanup_deleted_account_teams()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_team record; v_count integer := 0;
begin
  if not exists (select 1 from public.weeks where is_season_finale and is_complete)
     or public.league_trade_airing_locked() then return 0; end if;
  for v_team in select id, league_id from public.fantasy_teams
    where orphaned_by_account_deletion for update
  loop
    delete from public.league_trade_offers where initiator_team_id = v_team.id
      or counterparty_team_id = v_team.id or awaiting_team_id = v_team.id;
    delete from public.league_trade_events where initiator_team_id = v_team.id
      or counterparty_team_id = v_team.id or notification_team_id = v_team.id;
    delete from public.trade_offers where initiator_team_id = v_team.id
      or counterparty_team_id = v_team.id or awaiting_team_id = v_team.id;
    delete from public.trade_history where initiator_team_id = v_team.id
      or counterparty_team_id = v_team.id or notification_team_id = v_team.id;
    delete from public.league_weekly_roster_snapshots where fantasy_team_id = v_team.id;
    delete from public.weekly_roster_snapshots where fantasy_team_id = v_team.id;
    delete from public.league_draft_picks where fantasy_team_id = v_team.id;
    delete from public.league_draft_order where fantasy_team_id = v_team.id;
    delete from public.roster_history where fantasy_team_id = v_team.id;
    delete from public.league_roster_assignments where fantasy_team_id = v_team.id;
    update public.cast_members set fantasy_team_id = null where fantasy_team_id = v_team.id;
    delete from public.fantasy_teams where id = v_team.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.cleanup_deleted_account_teams() from public, anon, authenticated;

-- pg_cron is already used by the market sync. A recurring sweep also handles
-- accounts deleted after the finale was marked complete.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('cleanup-deleted-account-teams', '7 * * * *',
      'select public.cleanup_deleted_account_teams()');
  end if;
end $$;

commit;
notify pgrst, 'reload schema';
