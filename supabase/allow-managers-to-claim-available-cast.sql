-- Let a signed-in fantasy manager claim an available cast member only by
-- releasing one member of their own team. Commissioners retain the same
-- one-for-one control for league maintenance.
-- Run after enforce-one-for-one-roster-swaps.sql.

begin;

create or replace function public.swap_available_cast_member_into_team(
  p_team_id uuid,
  p_incoming_cast_member_id uuid,
  p_outgoing_cast_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_manager_team_id uuid;
begin
  select fantasy_team_id
  into v_manager_team_id
  from public.league_members
  where user_id = auth.uid();

  if not public.is_league_commissioner()
     and v_manager_team_id is distinct from p_team_id then
    raise exception 'You may only claim cast members for your own fantasy team.';
  end if;

  if p_incoming_cast_member_id = p_outgoing_cast_member_id then
    raise exception 'Choose two different cast members.';
  end if;

  if not exists (select 1 from public.fantasy_teams where id = p_team_id) then
    raise exception 'Fantasy team not found.';
  end if;

  perform 1
  from public.cast_members
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id)
  order by id
  for update;

  if (select count(*) from public.cast_members where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id)) <> 2 then
    raise exception 'One or more cast members could not be found.';
  end if;

  if (select fantasy_team_id from public.cast_members where id = p_incoming_cast_member_id) is not null then
    raise exception 'The incoming cast member is no longer available.';
  end if;

  if (select fantasy_team_id from public.cast_members where id = p_outgoing_cast_member_id) is distinct from p_team_id then
    raise exception 'The outgoing cast member is no longer on this team.';
  end if;

  perform public.expire_trade_offers_locked();

  if exists (
    select 1
    from public.trade_offers
    where initiator_cast_member_id = p_outgoing_cast_member_id
       or counterparty_cast_member_id = p_outgoing_cast_member_id
  ) then
    raise exception 'The outgoing cast member is part of an active trade offer.';
  end if;

  update public.cast_members
  set fantasy_team_id = case
    when id = p_incoming_cast_member_id then p_team_id
    else null
  end
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id);
end;
$$;

revoke all on function public.swap_available_cast_member_into_team(uuid, uuid, uuid) from public, anon;
grant execute on function public.swap_available_cast_member_into_team(uuid, uuid, uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
