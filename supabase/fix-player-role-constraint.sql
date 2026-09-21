-- One-time repair for databases created with the original lower-case role list.
-- Run this in Supabase Dashboard → SQL Editor.
alter table public.players drop constraint if exists players_role_check;

alter table public.players add constraint players_role_check
check (role in (
  'Star',
  'Pro',
  'Eliminated Star',
  'Eliminated Pro',
  'Troupe',
  'DWTS Next Pro',
  'Hough',
  'Judges + Hosts',
  'Surprise'
));
