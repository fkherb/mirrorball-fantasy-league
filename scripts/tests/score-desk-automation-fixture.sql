-- TEST ONLY: after automation fixture + all three automation migrations.
alter table public.weeks add column theme text, add column title text;
create or replace function public.is_platform_admin() returns boolean language sql as $$ select current_setting('test.owner',true)='yes' $$;
-- Minimal dependency stub isolates atomic wrapper behavior from show scoring.
create function public.update_week_setup_with_market_schedule(
  p_week_id uuid,p_theme text,p_title text,p_guest_judge_name text,p_double_elimination boolean,p_is_finale boolean,p_dance_ids uuid[],
  p_air_date date,p_second_air_date date,p_is_season_finale boolean,p_air_start_time time,p_air_end_time time,p_second_air_start_time time,p_second_air_end_time time,p_elimination_predictions_enabled boolean
) returns void language plpgsql as $$ begin
  update public.weeks set title=p_title,theme=p_theme,guest_judge_name=p_guest_judge_name where id=p_week_id;
  if p_title='force rollback' then raise exception 'Fixture simulated failure'; end if;
end $$;
