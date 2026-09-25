-- Mirrorball Fantasy League: trade cancellation and accurate counter history.
-- Run after enhance-trade-expiration-history.sql.

begin;

alter table public.trade_history
  drop constraint if exists trade_history_event_type_check;

alter table public.trade_history
  add constraint trade_history_event_type_check
  check (event_type in ('countered', 'accepted', 'denied', 'expired', 'cancelled'));

-- The previous counter function stored the replacement terms instead of the
-- offer being declined. Those test records cannot be reconstructed reliably.
delete from public.trade_history where event_type = 'countered';

create or replace function public.record_trade_history_event(
  p_trade public.trade_offers,
  p_event_type text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_initiator_team_name text;
  v_counterparty_team_name text;
  v_initiator_cast_name text;
  v_counterparty_cast_name text;
begin
  if p_event_type not in ('countered', 'accepted', 'denied', 'expired', 'cancelled') then
    raise exception 'Invalid trade history event.';
  end if;

  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_initiator_team_name from public.fantasy_teams where id = p_trade.initiator_team_id;
  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team')
    into v_counterparty_team_name from public.fantasy_teams where id = p_trade.counterparty_team_id;
  select name into v_initiator_cast_name from public.cast_members where id = p_trade.initiator_cast_member_id;
  select name into v_counterparty_cast_name from public.cast_members where id = p_trade.counterparty_cast_member_id;

  insert into public.trade_history (
    trade_id, event_type,
    initiator_team_id, counterparty_team_id,
    initiator_team_name, counterparty_team_name,
    initiator_cast_member_id, counterparty_cast_member_id,
    initiator_cast_member_name, counterparty_cast_member_name
  ) values (
    p_trade.id, p_event_type,
    p_trade.initiator_team_id, p_trade.counterparty_team_id,
    coalesce(v_initiator_team_name, 'Former team'), coalesce(v_counterparty_team_name, 'Former team'),
    p_trade.initiator_cast_member_id, p_trade.counterparty_cast_member_id,
    coalesce(v_initiator_cast_name, 'Former cast member'), coalesce(v_counterparty_cast_name, 'Former cast member')
  );
end;
$$;

create or replace function public.counter_trade(
  p_trade_id uuid,
  p_initiator_cast_member_id uuid,
  p_counterparty_cast_member_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
  v_changed_count integer;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.status <> 'pending' or v_trade.awaiting_team_id <> v_my_team_id or v_trade.counterparty_team_id <> v_my_team_id then
    raise exception 'This trade cannot be countered by your team.';
  end if;

  v_changed_count :=
    (case when p_initiator_cast_member_id is distinct from v_trade.initiator_cast_member_id then 1 else 0 end) +
    (case when p_counterparty_cast_member_id is distinct from v_trade.counterparty_cast_member_id then 1 else 0 end);
  if v_changed_count <> 1 then raise exception 'A counter must change exactly one side of the offer.'; end if;
  if p_initiator_cast_member_id = p_counterparty_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform 1 from public.cast_members where id in (p_initiator_cast_member_id, p_counterparty_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = p_initiator_cast_member_id) is distinct from v_trade.initiator_team_id then
    raise exception 'The requested cast member is no longer on the original manager’s team.';
  end if;
  if (select fantasy_team_id from public.cast_members where id = p_counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'The cast member you are offering is no longer on your team.';
  end if;
  if exists (
    select 1 from public.trade_offers
    where id <> p_trade_id
      and (
        p_initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
        or p_counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
      )
  ) then
    raise exception 'One of these cast members is already part of another active trade offer.';
  end if;

  -- Preserve the offer that was declined before replacing it with the counter.
  perform public.record_trade_history_event(v_trade, 'countered');
  update public.trade_offers
  set initiator_cast_member_id = p_initiator_cast_member_id,
      counterparty_cast_member_id = p_counterparty_cast_member_id,
      status = 'countered',
      awaiting_team_id = initiator_team_id,
      updated_at = now(),
      expires_at = now() + interval '48 hours'
  where id = p_trade_id;
end;
$$;

create or replace function public.cancel_trade(p_trade_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_trade public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_my_team_id not in (v_trade.initiator_team_id, v_trade.counterparty_team_id) then
    raise exception 'This trade does not belong to your team.';
  end if;
  if v_trade.awaiting_team_id = v_my_team_id then
    raise exception 'This offer is waiting for your response and cannot be cancelled by your team.';
  end if;
  perform public.record_trade_history_event(v_trade, 'cancelled');
  delete from public.trade_offers where id = p_trade_id;
end;
$$;

revoke all on function public.record_trade_history_event(public.trade_offers, text) from public, anon, authenticated;
revoke all on function public.cancel_trade(uuid) from public, anon;
grant execute on function public.cancel_trade(uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
