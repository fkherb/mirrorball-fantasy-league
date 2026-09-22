-- RUN THIS FIRST if allow-week-corrections-and-rate-ledger.sql was blocked by
-- “This week is complete and its setup is read-only.”
-- This is safe to run more than once.

drop trigger if exists prevent_completed_dance_edit on public.dances;
drop trigger if exists prevent_completed_judge_score_edit on public.dance_judge_scores;
drop trigger if exists prevent_completed_appearance_edit on public.dance_appearances;
drop trigger if exists prevent_completed_week_metadata_edit on public.weeks;
