-- Mirrorball Fantasy League: edit completed-week show details from the Ledger.
-- Run once after add-week-airing-dates.sql.

begin;

create or replace function public.update_completed_week_details(
  p_week_id uuid,
  p_theme text,
  p_title text,
  p_air_date date,
  p_second_air_date date,
  p_guest_judge_name text,
  p_double_elimination boolean,
  p_is_finale boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_week public.weeks%rowtype;
  v_old_guest text;
  v_new_guest text := nullif(trim(p_guest_judge_name), '');
  v_eliminated_couples integer;
  v_expected_eliminations integer;
begin
  if not public.is_league_commissioner() then
    raise exception 'Commissioner access is required.';
  end if;

  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if not v_week.is_complete then raise exception 'Use the regular week editor until this week is complete.'; end if;

  if p_second_air_date is not null and p_air_date is null then
    raise exception 'Choose the first airing date before adding a second night.';
  end if;
  if p_second_air_date is not null and p_second_air_date < p_air_date then
    raise exception 'The second night cannot be before the first night.';
  end if;
  if v_new_guest is not null and lower(v_new_guest) = any(array['carrie ann','derek','bruno']::text[]) then
    raise exception 'The guest judge name must differ from the regular judges.';
  end if;

  select count(*) into v_eliminated_couples
  from public.partnerships pair
  join public.cast_members star on star.id = pair.star_id
  join public.cast_members pro on pro.id = pair.pro_id
  where star.eliminated_week_id = p_week_id and pro.eliminated_week_id = p_week_id;

  v_expected_eliminations := case when p_is_finale then 0 when p_double_elimination then 2 else 1 end;
  if v_eliminated_couples <> v_expected_eliminations then
    raise exception 'This format expects % eliminated couple(s), but this week has % recorded.', v_expected_eliminations, v_eliminated_couples;
  end if;

  v_old_guest := nullif(trim(v_week.guest_judge_name), '');
  if v_old_guest is distinct from v_new_guest then
    if exists (select 1 from public.dances where week_id = p_week_id and kind = 'competitive')
       and (v_old_guest is null or v_new_guest is null) then
      raise exception 'After completion, you can rename the recorded guest judge but cannot add or remove one.';
    end if;
    if v_old_guest is not null and v_new_guest is not null then
      update public.dance_judge_scores score
      set judge_name = v_new_guest
      from public.dances dance
      where score.dance_id = dance.id
        and dance.week_id = p_week_id
        and score.judge_name = v_old_guest;
    end if;
  end if;

  update public.weeks
  set theme = nullif(trim(p_theme), ''),
      title = nullif(trim(p_title), ''),
      air_date = p_air_date,
      second_air_date = p_second_air_date,
      guest_judge_name = v_new_guest,
      double_elimination = case when p_is_finale then false else p_double_elimination end,
      is_finale = p_is_finale
  where id = p_week_id;
end;
$$;

revoke all on function public.update_completed_week_details(uuid,text,text,date,date,text,boolean,boolean) from public, anon;
grant execute on function public.update_completed_week_details(uuid,text,text,date,date,text,boolean,boolean) to authenticated;

commit;

notify pgrst, 'reload schema';
