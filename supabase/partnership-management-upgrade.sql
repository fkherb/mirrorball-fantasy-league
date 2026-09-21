alter table public.players drop constraint if exists players_role_check;
alter table public.players add constraint players_role_check check (role in ('Star','Pro','Eliminated Star','Eliminated Pro','Troupe','DWTS Next Pro','Hough','Judges + Hosts','Surprise'));
-- Images are automatic: Images/<name with punctuation removed>.jpg
