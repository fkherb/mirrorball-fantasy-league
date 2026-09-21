-- Run once in Supabase Dashboard → SQL Editor.
-- Keeps team and roster data public to read, while commissioner write policies remain separate.
alter table public.fantasy_teams enable row level security;
alter table public.roster_history enable row level security;

drop policy if exists "public read teams" on public.fantasy_teams;
create policy "public read teams" on public.fantasy_teams for select using (true);

drop policy if exists "public read rosters" on public.roster_history;
create policy "public read rosters" on public.roster_history for select using (true);
