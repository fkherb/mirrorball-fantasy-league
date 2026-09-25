-- Mirrorball Fantasy League: manager-to-manager one-for-one trading.
-- Run after add-league-member-accounts.sql. All mutations are intentionally
-- routed through the authenticated RPCs below.

begin;

create table if not exists public.trade_offers (
  id uuid primary key default gen_random_uuid(),
  initiator_team_id uuid not null references public.fantasy_teams(id) on delete cascade,
  counterparty_team_id uuid not null references public.fantasy_teams(id) on delete cascade,
  initiator_cast_member_id uuid not null references public.cast_members(id) on delete cascade,
  counterparty_cast_member_id uuid not null references public.cast_members(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'countered')),
  awaiting_team_id uuid not null references public.fantasy_teams(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (initiator_team_id <> counterparty_team_id),
  check (initiator_cast_member_id <> counterparty_cast_member_id),
  check (awaiting_team_id in (initiator_team_id, counterparty_team_id))
);

create index if not exists trade_offers_awaiting_team_idx on public.trade_offers (awaiting_team_id, updated_at desc);
create index if not exists trade_offers_initiator_team_idx on public.trade_offers (initiator_team_id, updated_at desc);
create index if not exists trade_offers_counterparty_team_idx on public.trade_offers (counterparty_team_id, updated_at desc);

create or replace function public.current_league_team_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select fantasy_team_id
  from public.league_members
  where user_id = auth.uid();
$$;

revoke all on function public.current_league_team_id() from public, anon;
grant execute on function public.current_league_team_id() to authenticated;

alter table public.trade_offers enable row level security;
drop policy if exists "managers read their trades" on public.trade_offers;
create policy "managers read their trades"
on public.trade_offers
for select
to authenticated
using (
  initiator_team_id = public.current_league_team_id()
  or counterparty_team_id = public.current_league_team_id()
);

grant select on public.trade_offers to authenticated;
revoke insert, update, delete on public.trade_offers from anon, authenticated;

create or replace function public.request_trade(
  p_my_cast_member_id uuid,
  p_requested_cast_member_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_my_team_id uuid;
  v_other_team_id uuid;
  v_trade_id uuid;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  if p_my_cast_member_id = p_requested_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform 1 from public.cast_members where id in (p_my_cast_member_id, p_requested_cast_member_id) for update;
  if (select fantasy_team_id from public.cast_members where id = p_my_cast_member_id) is distinct from v_my_team_id then
    raise exception 'The cast member you are offering is no longer on your team.';
  end if;
  select fantasy_team_id into v_other_team_id from public.cast_members where id = p_requested_cast_member_id;
  if v_other_team_id is null or v_other_team_id = v_my_team_id then
    raise exception 'Choose a cast member from another fantasy team.';
  end if;
  if exists (
    select 1 from public.trade_offers
    where p_my_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
       or p_requested_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
  ) then
    raise exception 'One of these cast members is already part of an active trade offer.';
  end if;

  insert into public.trade_offers (
    initiator_team_id, counterparty_team_id,
    initiator_cast_member_id, counterparty_cast_member_id,
    status, awaiting_team_id
  ) values (
    v_my_team_id, v_other_team_id,
    p_my_cast_member_id, p_requested_cast_member_id,
    'pending', v_other_team_id
  ) returning id into v_trade_id;

  return v_trade_id;
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

  update public.trade_offers
  set initiator_cast_member_id = p_initiator_cast_member_id,
      counterparty_cast_member_id = p_counterparty_cast_member_id,
      status = 'countered',
      awaiting_team_id = initiator_team_id,
      updated_at = now()
  where id = p_trade_id;
end;
$$;

create or replace function public.accept_trade(p_trade_id uuid)
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
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'This trade is waiting for the other manager.'; end if;

  perform 1 from public.cast_members
  where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id)
  for update;
  if (select fantasy_team_id from public.cast_members where id = v_trade.initiator_cast_member_id) is distinct from v_trade.initiator_team_id
     or (select fantasy_team_id from public.cast_members where id = v_trade.counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'A cast member changed teams after this offer was created. The trade can no longer be accepted.';
  end if;

  update public.cast_members
  set fantasy_team_id = case
    when id = v_trade.initiator_cast_member_id then v_trade.counterparty_team_id
    when id = v_trade.counterparty_cast_member_id then v_trade.initiator_team_id
  end
  where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id);

  -- Any competing offers involving either newly traded cast member are stale.
  delete from public.trade_offers
  where v_trade.initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
     or v_trade.counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id);
end;
$$;

create or replace function public.deny_trade(p_trade_id uuid)
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
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'Only the manager reviewing this offer can deny it.'; end if;
  delete from public.trade_offers where id = p_trade_id;
end;
$$;

revoke all on function public.request_trade(uuid, uuid) from public, anon;
revoke all on function public.counter_trade(uuid, uuid, uuid) from public, anon;
revoke all on function public.accept_trade(uuid) from public, anon;
revoke all on function public.deny_trade(uuid) from public, anon;
grant execute on function public.request_trade(uuid, uuid) to authenticated;
grant execute on function public.counter_trade(uuid, uuid, uuid) to authenticated;
grant execute on function public.accept_trade(uuid) to authenticated;
grant execute on function public.deny_trade(uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
