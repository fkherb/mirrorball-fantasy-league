-- Mirrorball Fantasy League: optional one- or two-night weekly airing dates.
-- Run once in Supabase Dashboard -> SQL Editor after perfect-current-workflows.sql.

begin;

alter table public.weeks
  add column if not exists air_date date,
  add column if not exists second_air_date date;

alter table public.weeks
  drop constraint if exists weeks_air_dates_ordered;

alter table public.weeks
  add constraint weeks_air_dates_ordered
  check (
    second_air_date is null
    or (air_date is not null and second_air_date >= air_date)
  );

create or replace function public.update_week_setup_dates_and_order(
  p_week_id uuid,
  p_theme text,
  p_title text,
  p_guest_judge_name text,
  p_double_elimination boolean,
  p_is_finale boolean,
  p_dance_ids uuid[],
  p_air_date date,
  p_second_air_date date
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if p_second_air_date is not null and p_air_date is null then
    raise exception 'Choose the first airing date before adding a second night.';
  end if;
  if p_second_air_date is not null and p_second_air_date < p_air_date then
    raise exception 'The second night cannot be before the first night.';
  end if;

  perform public.update_week_setup_and_order(
    p_week_id,
    p_theme,
    p_title,
    p_guest_judge_name,
    p_double_elimination,
    p_is_finale,
    p_dance_ids
  );

  update public.weeks
  set air_date = p_air_date,
      second_air_date = p_second_air_date
  where id = p_week_id;
end;
$$;

revoke all on function public.update_week_setup_dates_and_order(uuid,text,text,text,boolean,boolean,uuid[],date,date) from public, anon;
grant execute on function public.update_week_setup_dates_and_order(uuid,text,text,text,boolean,boolean,uuid[],date,date) to authenticated;

commit;

notify pgrst, 'reload schema';
