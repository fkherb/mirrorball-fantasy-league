-- Run once in Supabase Dashboard → SQL Editor.
-- The site is public to browse; only the commissioner can change this data.
grant usage on schema public to anon, authenticated;
grant select on public.fantasy_teams, public.cast_members, public.roles, public.partnerships, public.weeks to anon, authenticated;

alter table public.fantasy_teams enable row level security;
alter table public.cast_members enable row level security;
alter table public.roles enable row level security;
alter table public.partnerships enable row level security;
alter table public.weeks enable row level security;

drop policy if exists "public read fantasy teams" on public.fantasy_teams;
create policy "public read fantasy teams" on public.fantasy_teams for select using (true);
drop policy if exists "public read cast members" on public.cast_members;
create policy "public read cast members" on public.cast_members for select using (true);
drop policy if exists "public read roles" on public.roles;
create policy "public read roles" on public.roles for select using (true);
drop policy if exists "public read partnerships" on public.partnerships;
create policy "public read partnerships" on public.partnerships for select using (true);
drop policy if exists "public read weeks" on public.weeks;
create policy "public read weeks" on public.weeks for select using (true);
