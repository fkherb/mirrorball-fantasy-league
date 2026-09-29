-- Run after add-kalshi-market-predictions.sql and separate-cast-source-and-league-settings.sql.
-- Airing times are Eastern wall-clock times; dates already live on public.weeks.
begin;

alter table public.weeks
  add column if not exists air_start_time time without time zone not null default time '20:00',
  add column if not exists air_end_time time without time zone not null default time '22:00',
  add column if not exists second_air_start_time time without time zone,
  add column if not exists second_air_end_time time without time zone,
  add column if not exists elimination_predictions_enabled boolean not null default false;

alter table public.weeks drop constraint if exists week_prediction_airing_times_valid;
alter table public.weeks add constraint week_prediction_airing_times_valid check (
  air_start_time < air_end_time
  and (second_air_start_time is null or second_air_end_time is null
       or second_air_start_time < second_air_end_time)
);

alter table public.cast_market_predictions
  add column if not exists bid_percent numeric(5,1),
  add column if not exists ask_percent numeric(5,1),
  add column if not exists quote_source text;

create table if not exists public.cast_market_prediction_history (
  market_ticker text not null,
  event_ticker text not null,
  cast_member_id uuid not null references public.cast_members(id) on delete cascade,
  market_kind text not null check (market_kind in
    ('winner','second','third','top_three','finalist','elimination')),
  week_id uuid references public.weeks(id) on delete cascade,
  snapshot_bucket timestamptz not null,
  observed_at timestamptz not null,
  quote_at timestamptz,
  percent numeric(5,1) not null check (percent between 0 and 100),
  bid_percent numeric(5,1) check (bid_percent between 0 and 100),
  ask_percent numeric(5,1) check (ask_percent between 0 and 100),
  last_percent numeric(5,1) check (last_percent between 0 and 100),
  quote_source text not null check (quote_source in ('midpoint','last')),
  market_status text not null,
  source text not null default 'live' check (source in ('live','historical_backfill')),
  primary key (market_ticker, snapshot_bucket),
  check ((market_kind = 'elimination') = (week_id is not null))
);
create index if not exists cast_market_prediction_history_chart_idx
  on public.cast_market_prediction_history (cast_member_id, market_kind, observed_at);

create table if not exists public.market_prediction_sync_state (
  id integer primary key default 1 check (id = 1),
  refreshed_at timestamptz,
  snapshot_bucket timestamptz
);
insert into public.market_prediction_sync_state (id) values (1) on conflict (id) do nothing;

alter table public.cast_market_prediction_history enable row level security;
alter table public.market_prediction_sync_state enable row level security;
drop policy if exists "read market prediction history" on public.cast_market_prediction_history;
create policy "read market prediction history" on public.cast_market_prediction_history
  for select to anon, authenticated using (true);
revoke all on public.cast_market_prediction_history, public.market_prediction_sync_state
  from public, anon, authenticated;
grant select on public.cast_market_prediction_history to anon, authenticated;
grant select, insert on public.cast_market_prediction_history to service_role;
grant select, insert, update on public.market_prediction_sync_state to service_role;
grant select on public.cast_members, public.partnerships to service_role;

create or replace function public.update_week_setup_with_market_schedule(
  p_week_id uuid, p_theme text, p_title text, p_guest_judge_name text,
  p_double_elimination boolean, p_is_finale boolean, p_dance_ids uuid[],
  p_air_date date, p_second_air_date date, p_is_season_finale boolean,
  p_air_start_time time without time zone, p_air_end_time time without time zone,
  p_second_air_start_time time without time zone, p_second_air_end_time time without time zone,
  p_elimination_predictions_enabled boolean
) returns void language plpgsql security invoker set search_path = public as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Platform-owner access is required.';
  end if;
  if p_air_start_time is null or p_air_end_time is null or p_air_start_time >= p_air_end_time then
    raise exception 'The first airing end time must be after its start time.';
  end if;
  if p_second_air_date is not null and
     (p_second_air_start_time is null or p_second_air_end_time is null
      or p_second_air_start_time >= p_second_air_end_time) then
    raise exception 'The second airing end time must be after its start time.';
  end if;
  if p_elimination_predictions_enabled and p_air_date is null then
    raise exception 'Set an air date before enabling weekly elimination predictions.';
  end if;
  perform public.update_week_setup_and_finale(p_week_id, p_theme, p_title,
    p_guest_judge_name, p_double_elimination, p_is_finale, p_dance_ids,
    p_air_date, p_second_air_date, p_is_season_finale);
  update public.weeks set
    air_start_time = p_air_start_time,
    air_end_time = p_air_end_time,
    second_air_start_time = case when p_second_air_date is null then null else p_second_air_start_time end,
    second_air_end_time = case when p_second_air_date is null then null else p_second_air_end_time end,
    elimination_predictions_enabled = coalesce(p_elimination_predictions_enabled, false) and not p_is_finale
  where id = p_week_id;
end;
$$;
revoke all on function public.update_week_setup_with_market_schedule(
  uuid,text,text,text,boolean,boolean,uuid[],date,date,boolean,time,time,time,time,boolean)
  from public, anon;
grant execute on function public.update_week_setup_with_market_schedule(
  uuid,text,text,text,boolean,boolean,uuid[],date,date,boolean,time,time,time,time,boolean)
  to authenticated;

commit;
