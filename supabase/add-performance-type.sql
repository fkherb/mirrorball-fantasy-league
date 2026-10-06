-- Run once in Supabase SQL Editor before using the performance Type field.
-- Existing performance details and historical scores are unchanged.
alter table public.dances add column if not exists performance_type text;
