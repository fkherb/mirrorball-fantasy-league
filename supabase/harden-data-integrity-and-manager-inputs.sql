-- Mirrorball Fantasy League: data-integrity and manager-input hardening.
-- Run after fix-trade-counter-history-and-cancellation.sql and
-- allow-managers-to-claim-available-cast.sql.

begin;

alter table public.trade_history
  drop constraint if exists trade_history_event_type_check;
alter table public.trade_history
  add constraint trade_history_event_type_check
  check (event_type in ('countered', 'accepted', 'denied', 'expired', 'cancelled', 'invalidated'));

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'league_members_first_name_length_check') then
    alter table public.league_members add constraint league_members_first_name_length_check
      check (char_length(first_name) between 1 and 40) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'league_members_last_name_length_check') then
    alter table public.league_members add constraint league_members_last_name_length_check
      check (char_length(last_name) between 1 and 50) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'league_members_custom_nav_length_check') then
    alter table public.league_members add constraint league_members_custom_nav_length_check
      check (custom_team_nav_label is null or char_length(custom_team_nav_label) between 1 and 24) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fantasy_teams_team_name_length_check') then
    alter table public.fantasy_teams add constraint fantasy_teams_team_name_length_check
      check (team_name is null or char_length(team_name) between 1 and 80) not valid;
  end if;
end $$;

create or replace function public.update_my_team_profile(
  p_first_name text,
  p_last_name text,
  p_team_name text,
  p_nav_label_mode text default 'default',
  p_custom_nav_label text default null
)
returns public.league_members
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_member public.league_members;
  member_team_id uuid;
  v_first_name text := trim(coalesce(p_first_name, ''));
  v_last_name text := trim(coalesce(p_last_name, ''));
  v_team_name text := nullif(trim(coalesce(p_team_name, '')), '');
  v_custom_label text := nullif(trim(coalesce(p_custom_nav_label, '')), '');
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if v_first_name = '' or v_last_name = '' then raise exception 'First and last name are required.'; end if;
  if char_length(v_first_name) > 40 then raise exception 'First name must be 40 characters or fewer.'; end if;
  if char_length(v_last_name) > 50 then raise exception 'Last name must be 50 characters or fewer.'; end if;
  if v_team_name is not null and char_length(v_team_name) > 80 then raise exception 'Team name must be 80 characters or fewer.'; end if;
  if p_nav_label_mode is null or p_nav_label_mode not in ('default', 'team', 'custom') then raise exception 'Invalid My Team label option.'; end if;
  if p_nav_label_mode = 'custom' and v_custom_label is null then raise exception 'Enter a custom My Team label.'; end if;
  if v_custom_label is not null and char_length(v_custom_label) > 24 then raise exception 'Navigation label must be 24 characters or fewer.'; end if;

  select fantasy_team_id into member_team_id
  from public.league_members where user_id = auth.uid();
  if member_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;

  update public.league_members
  set first_name = v_first_name,
      last_name = v_last_name,
      team_nav_label_mode = p_nav_label_mode,
      custom_team_nav_label = case when p_nav_label_mode = 'custom' then v_custom_label else null end,
      updated_at = now()
  where user_id = auth.uid()
  returning * into updated_member;

  update public.fantasy_teams set team_name = v_team_name where id = member_team_id;
  return updated_member;
end;
$$;

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
  if p_event_type not in ('countered', 'accepted', 'denied', 'expired', 'cancelled', 'invalidated') then
    raise exception 'Invalid trade history event.';
  end if;
  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team') into v_initiator_team_name
    from public.fantasy_teams where id = p_trade.initiator_team_id;
  select coalesce(team_name, split_part(manager_name, ' ', 1) || '''s Team') into v_counterparty_team_name
    from public.fantasy_teams where id = p_trade.counterparty_team_id;
  select name into v_initiator_cast_name from public.cast_members where id = p_trade.initiator_cast_member_id;
  select name into v_counterparty_cast_name from public.cast_members where id = p_trade.counterparty_cast_member_id;
  insert into public.trade_history (
    trade_id, event_type, initiator_team_id, counterparty_team_id,
    initiator_team_name, counterparty_team_name,
    initiator_cast_member_id, counterparty_cast_member_id,
    initiator_cast_member_name, counterparty_cast_member_name
  ) values (
    p_trade.id, p_event_type, p_trade.initiator_team_id, p_trade.counterparty_team_id,
    coalesce(v_initiator_team_name, 'Former team'), coalesce(v_counterparty_team_name, 'Former team'),
    p_trade.initiator_cast_member_id, p_trade.counterparty_cast_member_id,
    coalesce(v_initiator_cast_name, 'Former cast member'), coalesce(v_counterparty_cast_name, 'Former cast member')
  );
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
  v_competing public.trade_offers;
begin
  v_my_team_id := public.current_league_team_id();
  if v_my_team_id is null then raise exception 'This account is not connected to a fantasy team.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-trades', 0));
  perform public.expire_trade_offers_locked();
  select * into v_trade from public.trade_offers where id = p_trade_id for update;
  if v_trade.id is null then raise exception 'This trade offer is no longer available.'; end if;
  if v_trade.awaiting_team_id <> v_my_team_id then raise exception 'This trade is waiting for the other manager.'; end if;

  perform 1 from public.cast_members
    where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id)
    order by id for update;
  if (select fantasy_team_id from public.cast_members where id = v_trade.initiator_cast_member_id) is distinct from v_trade.initiator_team_id
     or (select fantasy_team_id from public.cast_members where id = v_trade.counterparty_cast_member_id) is distinct from v_trade.counterparty_team_id then
    raise exception 'A cast member changed teams after this offer was created. The trade can no longer be accepted.';
  end if;

  perform public.record_trade_history_event(v_trade, 'accepted');
  for v_competing in
    select * from public.trade_offers
    where id <> v_trade.id and (
      v_trade.initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
      or v_trade.counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
    ) for update
  loop
    perform public.record_trade_history_event(v_competing, 'invalidated');
  end loop;

  update public.cast_members
  set fantasy_team_id = case
    when id = v_trade.initiator_cast_member_id then v_trade.counterparty_team_id
    when id = v_trade.counterparty_cast_member_id then v_trade.initiator_team_id
  end
  where id in (v_trade.initiator_cast_member_id, v_trade.counterparty_cast_member_id);

  delete from public.trade_offers
  where v_trade.initiator_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
     or v_trade.counterparty_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id);
end;
$$;

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
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select fantasy_team_id into v_manager_team_id
  from public.league_members where user_id = auth.uid();
  if v_manager_team_id is null or v_manager_team_id is distinct from p_team_id then
    raise exception 'You may only claim cast members for your own fantasy team.';
  end if;
  if p_incoming_cast_member_id = p_outgoing_cast_member_id then raise exception 'Choose two different cast members.'; end if;

  perform pg_advisory_xact_lock(hashtextextended('mirrorball-fantasy-roster-swaps', 0));
  perform 1 from public.cast_members
    where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id)
    order by id for update;
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
    select 1 from public.trade_offers
    where p_outgoing_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
       or p_incoming_cast_member_id in (initiator_cast_member_id, counterparty_cast_member_id)
  ) then
    raise exception 'One of these cast members is part of an active trade offer.';
  end if;

  update public.cast_members
  set fantasy_team_id = case when id = p_incoming_cast_member_id then p_team_id else null end
  where id in (p_incoming_cast_member_id, p_outgoing_cast_member_id);
end;
$$;

revoke all on function public.record_trade_history_event(public.trade_offers, text) from public, anon, authenticated;
revoke all on function public.accept_trade(uuid) from public, anon;
revoke all on function public.swap_available_cast_member_into_team(uuid, uuid, uuid) from public, anon;
grant execute on function public.accept_trade(uuid) to authenticated;
grant execute on function public.swap_available_cast_member_into_team(uuid, uuid, uuid) to authenticated;

commit;

notify pgrst, 'reload schema';
