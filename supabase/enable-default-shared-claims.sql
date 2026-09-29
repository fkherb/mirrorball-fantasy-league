-- Let the original league use the shared claim RPC after the UI cutover,
-- while its legacy cast-team column remains the authoritative write source.
-- No website route or existing legacy claim RPC is changed by this patch.
-- Run after airing-trade-and-draft-windows.sql. Safe to rerun.
begin;

do $$
begin
  if to_regprocedure('public.claim_league_cast_member_without_default(uuid,uuid,uuid)') is null then
    execute 'alter function public.claim_league_cast_member(uuid,uuid,uuid) '
      || 'rename to claim_league_cast_member_without_default';
  end if;
end;
$$;
revoke all on function public.claim_league_cast_member_without_default(uuid,uuid,uuid)
  from public, anon, authenticated;

create or replace function public.claim_league_cast_member(
  p_league_id uuid, p_incoming_cast_member_id uuid,
  p_outgoing_cast_member_id uuid default null
)
returns void language plpgsql security definer set search_path = '' as $$
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
revoke all on function public.claim_league_cast_member(uuid,uuid,uuid)
  from public, anon;
grant execute on function public.claim_league_cast_member(uuid,uuid,uuid)
  to authenticated;

commit;
