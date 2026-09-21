-- Run once in Supabase SQL Editor after schema.sql.
alter table public.players add column if not exists image_path text;

-- Replace the placeholder with your commissioner email before running.
-- This lets only that signed-in Supabase account create or change league data.
-- create policy "commissioner writes players" on public.players for all to authenticated
-- using ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL')
-- with check ((auth.jwt() ->> 'email') = 'YOUR_COMMISSIONER_EMAIL');
-- Repeat this policy pattern for fantasy_teams, weeks, partnerships,
-- roster_history, and score_events.
