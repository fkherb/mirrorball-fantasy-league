-- Run once in Supabase SQL Editor before assigning dances to nights.
-- Leave existing dances unassigned until the platform owner selects their night.
alter table public.dances
  add column if not exists airing_night smallint
  constraint dances_airing_night_check check (airing_night in (1, 2));
