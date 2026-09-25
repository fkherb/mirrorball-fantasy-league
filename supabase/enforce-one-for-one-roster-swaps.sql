-- Keep every established fantasy-team roster the same size when adding a
-- newly available cast member. Run after optimize-current-query-indexes.sql.

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
begin
  if not public.is_league_commissioner() then
    raise exception 'Commissioner access is required.';
  end if;

  if p_incoming_cast_member_id = p_outgoing_cast_member_id then
    raise exception 'Choose two different cast members.';
  end if;

  if not exists (select 1 from public.fantasy_teams where id = p_team_id) then
    raise exception 'Fantasy team not found.';
  end if;

  -- Lock both records together so two simultaneous requests cannot assign the
  -- same free agent or release the same roster member.
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

-- Retire the independent add/remove routes. Platform-owner maintenance still
-- has its existing direct policy; league commissioners use the atomic swap.
revoke all on function public.assign_cast_members_to_team(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.remove_cast_member_from_team(uuid, uuid) from public, anon, authenticated;
revoke all on function public.swap_available_cast_member_into_team(uuid, uuid, uuid) from public, anon;
grant execute on function public.swap_available_cast_member_into_team(uuid, uuid, uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
