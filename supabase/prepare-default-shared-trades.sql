-- Prepare the original league's shared trade path without activating it.
-- Newer leagues keep their current behavior. This migration leaves the
-- original league on legacy trades until shared_workspace_enabled is set true
-- in a separate, gated cutover transaction. Do not toggle that flag here.
-- Run after shadow-default-league-trade-history.sql and
-- airing-trade-and-draft-windows.sql. Safe to rerun.
begin;

alter table public.leagues add column if not exists shared_workspace_enabled boolean;
update public.leagues set shared_workspace_enabled =
  id <> public.default_fantasy_league_id()
where shared_workspace_enabled is null;
alter table public.leagues alter column shared_workspace_enabled set default true;
alter table public.leagues alter column shared_workspace_enabled set not null;

-- While the original league is on the old UI, only legacy offers may be
-- created. After cutover, only shared offers may be created. Check the team
-- rather than NEW.league_id: the existing legacy scope trigger may run later.
create or replace function public.guard_default_legacy_trade_path()
returns trigger language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.guard_default_legacy_trade_path()
  from public, anon, authenticated;
drop trigger if exists guard_default_legacy_trade_path on public.trade_offers;
create trigger guard_default_legacy_trade_path
before insert or update on public.trade_offers
for each row execute function public.guard_default_legacy_trade_path();

create or replace function public.guard_default_shared_trade_path()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.league_id = public.default_fantasy_league_id()
     and not (select shared_workspace_enabled from public.leagues where id = new.league_id) then
    raise exception 'This league has not switched to the updated trade center yet.';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_default_shared_trade_path()
  from public, anon, authenticated;
drop trigger if exists guard_default_shared_trade_path on public.league_trade_offers;
create trigger guard_default_shared_trade_path
before insert or update on public.league_trade_offers
for each row execute function public.guard_default_shared_trade_path();

-- Keep accepted default-league trades in both roster representations. The
-- existing cast_members trigger then mirrors each legacy field update back
-- into league_roster_assignments. Every step is one database transaction.
do $$
begin
  if to_regprocedure('public.respond_to_league_trade_without_default(uuid,text,text,uuid)') is null then
    execute 'alter function public.respond_to_league_trade(uuid,text,text,uuid) '
      || 'rename to respond_to_league_trade_without_default';
  end if;
end;
$$;
revoke all on function public.respond_to_league_trade_without_default(uuid,text,text,uuid)
  from public, anon, authenticated;

create or replace function public.respond_to_league_trade(
  p_offer_id uuid, p_action text, p_replace_side text default null,
  p_replacement_cast_member_id uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.respond_to_league_trade(uuid,text,text,uuid)
  from public, anon;
grant execute on function public.respond_to_league_trade(uuid,text,text,uuid)
  to authenticated;

commit;
