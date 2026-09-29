-- Run after the cast profiles, partnerships, and week-airing-date migrations.
-- Kalshi predictions are shared show data, never fantasy scoring inputs.
begin;

create table if not exists public.cast_market_symbols (
  cast_member_id uuid primary key references public.cast_members(id) on delete cascade,
  ticker_suffix text not null unique check (ticker_suffix ~ '^[A-Z0-9]{2,8}$')
);

insert into public.cast_market_symbols (cast_member_id, ticker_suffix)
select cast_member.id, mapping.ticker_suffix
from (values
  ('Amber Glenn','AGLE'), ('Ciara Miller','CMIL'),
  ('Conner Leavitt','CLEV'), ('Connor Wood','CWOO'),
  ('Ezra Frech','EFRE'), ('Giada De Laurentiis','GDEL'),
  ('Guillermo Rodriguez','GROD'), ('Harry Shum Jr.','HSHU'),
  ('Jackson Olson','JOLS'), ('Jenna Dewan','JDEW'),
  ('Julia Stiles','JSTIL'), ('Maura Higgins','MHIG'),
  ('Sarah Jane Nader','SJAN'), ('Tatyana Ali','TAT'),
  ('Taylor Hanson','THAN'), ('Tyler Cameron','TCAM')
) as mapping(cast_name,ticker_suffix)
join public.cast_members cast_member on cast_member.name = mapping.cast_name
on conflict (cast_member_id) do update set ticker_suffix = excluded.ticker_suffix;

do $$
begin
  if (select count(*) from public.cast_market_symbols where ticker_suffix in
    ('AGLE','CMIL','CLEV','CWOO','EFRE','GDEL','GROD','HSHU',
     'JOLS','JDEW','JSTIL','MHIG','SJAN','TAT','THAN','TCAM')) <> 16 then
    raise exception 'A 2026 Kalshi ticker suffix did not match a cast member. Check the cast names before installing predictions.';
  end if;
end;
$$;

create table if not exists public.cast_market_predictions (
  market_ticker text primary key,
  event_ticker text not null,
  cast_member_id uuid not null references public.cast_members(id) on delete cascade,
  market_kind text not null check (market_kind in
    ('winner','second','third','top_three','finalist','elimination')),
  week_id uuid references public.weeks(id) on delete cascade,
  percent numeric(5,1) check (percent between 0 and 100),
  market_status text not null,
  market_result text,
  fetched_at timestamptz not null,
  check ((market_kind = 'elimination') = (week_id is not null))
);
create index if not exists cast_market_predictions_cast_week_idx
  on public.cast_market_predictions (cast_member_id, week_id, market_kind);

alter table public.cast_market_symbols enable row level security;
alter table public.cast_market_predictions enable row level security;
drop policy if exists "read cast market predictions" on public.cast_market_predictions;
create policy "read cast market predictions" on public.cast_market_predictions
  for select to anon, authenticated using (true);
revoke all on public.cast_market_symbols, public.cast_market_predictions
  from public, anon, authenticated;
grant select on public.cast_market_predictions to anon, authenticated;
grant select, insert, update, delete on public.cast_market_symbols,
  public.cast_market_predictions to service_role;
-- The sync function reads airing dates to choose the weekly elimination event.
grant select on public.weeks to service_role;

commit;
