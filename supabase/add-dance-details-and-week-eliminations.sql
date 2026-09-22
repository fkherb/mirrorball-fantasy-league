-- Run once in Supabase Dashboard → SQL Editor.
alter table public.dances add column if not exists dance_type text;
alter table public.dances add column if not exists song text;
alter table public.weeks add column if not exists is_finale boolean not null default false;
