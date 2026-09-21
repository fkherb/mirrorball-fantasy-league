-- Run once in Supabase Dashboard → SQL Editor.
alter table public.cast_members
add column if not exists image_position integer not null default 50
check (image_position between 0 and 100);

alter table public.partnerships
add column if not exists partnership_name text;
