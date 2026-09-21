-- Run once in Supabase Dashboard → SQL Editor before using the elimination controls.
alter table public.players
add column if not exists eliminated_week_id uuid references public.weeks(id);
