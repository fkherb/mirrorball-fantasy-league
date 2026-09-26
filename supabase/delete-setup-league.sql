-- Run after finish-league-draft-setup.sql. Adds owner-only deletion of an
-- undrafted secondary league; the original league and started drafts are safe.
begin;

create or replace function public.delete_fantasy_league(p_league_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league public.leagues;
begin
  if p_league_id is null or p_league_id = public.default_fantasy_league_id() then
    raise exception 'The original league cannot be deleted.';
  end if;
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  select * into v_league from public.leagues where id = p_league_id for update;
  if v_league.id is null then raise exception 'League not found.'; end if;
  if v_league.status <> 'setup' or v_league.draft_started_at is not null then
    raise exception 'A league can only be deleted before its draft starts.';
  end if;
  if exists (select 1 from public.league_draft_picks where league_id = p_league_id)
    or exists (select 1 from public.league_trade_offers where league_id = p_league_id)
    or exists (select 1 from public.league_weekly_roster_snapshots where league_id = p_league_id) then
    raise exception 'A league with draft picks, trades, or scored weeks cannot be deleted.';
  end if;

  delete from public.league_invites where league_id = p_league_id;
  delete from public.league_invite_links where league_id = p_league_id;
  delete from public.league_draft_order where league_id = p_league_id;
  delete from public.league_role_rates where league_id = p_league_id;
  delete from public.league_roster_assignments where league_id = p_league_id;
  delete from public.league_settings where league_id = p_league_id;
  delete from public.league_members where league_id = p_league_id;
  delete from public.fantasy_teams where league_id = p_league_id;
  delete from public.leagues where id = p_league_id;
end;
$$;

revoke all on function public.delete_fantasy_league(uuid) from public, anon, authenticated;
grant execute on function public.delete_fantasy_league(uuid) to authenticated;

commit;
notify pgrst, 'reload schema';
