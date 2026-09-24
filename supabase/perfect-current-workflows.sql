-- Mirrorball Fantasy League: harden the workflows already in use.
-- Run once in Supabase Dashboard -> SQL Editor after the account, score-desk,
-- and atomic-dance migrations listed in README.md.
--
-- This migration adds no new league feature. It makes current commissioner
-- edits atomic, moves authorization to league_members.is_commissioner, permits
-- the Week Ledger to add a missing completed-week performance, and preserves
-- a blank optional week title instead of generating "Theme Week".

begin;

do $$
begin
  if not exists (select 1 from public.league_members where is_commissioner = true) then
    raise exception 'Add or mark the commissioner in league_members before running this migration.';
  end if;
end;
$$;

-- Use the account-to-league membership as the sole write-authority source.
drop policy if exists "commissioner writes teams" on public.fantasy_teams;
create policy "commissioner writes teams" on public.fantasy_teams for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes weeks" on public.weeks;
create policy "commissioner writes weeks" on public.weeks for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes players" on public.cast_members;
drop policy if exists "commissioner writes cast members" on public.cast_members;
create policy "commissioner writes cast members" on public.cast_members for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes partnerships" on public.partnerships;
create policy "commissioner writes partnerships" on public.partnerships for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes dances" on public.dances;
create policy "commissioner writes dances" on public.dances for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes judge scores" on public.dance_judge_scores;
create policy "commissioner writes judge scores" on public.dance_judge_scores for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes dance appearances" on public.dance_appearances;
create policy "commissioner writes dance appearances" on public.dance_appearances for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes weekly roster snapshots" on public.weekly_roster_snapshots;
create policy "commissioner writes weekly roster snapshots" on public.weekly_roster_snapshots for all to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

drop policy if exists "commissioner writes roles" on public.roles;
create policy "commissioner writes roles" on public.roles for update to authenticated
  using (public.is_league_commissioner()) with check (public.is_league_commissioner());

-- Replace the old delete-then-insert partnership workflow with one transaction.
create or replace function public.set_cast_partnership_atomic(
  p_cast_member_id uuid,
  p_role text,
  p_partner_id uuid,
  p_partnership_name text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_pair_id uuid;
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if p_role not in ('Star', 'Pro') then raise exception 'A partnership member must be a star or pro.'; end if;
  perform 1 from public.cast_members where id = p_cast_member_id for update;
  if not found then raise exception 'Cast member not found.'; end if;
  if p_partner_id = p_cast_member_id then raise exception 'A cast member cannot partner with themselves.'; end if;
  if p_partner_id is not null then
    perform 1 from public.cast_members where id = p_partner_id for update;
    if not found then raise exception 'Partner not found.'; end if;
    if p_role = 'Star' and not exists (select 1 from public.cast_members where id=p_partner_id and role in ('Pro','Eliminated Pro')) then raise exception 'A star must be paired with a pro.'; end if;
    if p_role = 'Pro' and not exists (select 1 from public.cast_members where id=p_partner_id and role in ('Star','Eliminated Star')) then raise exception 'A pro must be paired with a star.'; end if;
  end if;

  select id into v_pair_id from public.partnerships
  where p_cast_member_id in (star_id, pro_id) and
    (case when star_id = p_cast_member_id then pro_id else star_id end) is not distinct from p_partner_id;
  if v_pair_id is not null then
    update public.partnerships set partnership_name = nullif(trim(p_partnership_name), ''), active = true where id = v_pair_id;
    return v_pair_id;
  end if;

  delete from public.partnerships where p_cast_member_id in (star_id, pro_id)
    or (p_partner_id is not null and p_partner_id in (star_id, pro_id));
  if p_partner_id is null then return null; end if;

  insert into public.partnerships (star_id, pro_id, active, partnership_name)
  values (
    case when p_role = 'Star' then p_cast_member_id else p_partner_id end,
    case when p_role = 'Pro' then p_cast_member_id else p_partner_id end,
    true,
    nullif(trim(p_partnership_name), '')
  ) returning id into v_pair_id;
  return v_pair_id;
end;
$$;

-- Cast details and their partnership change together, including new cast.
create or replace function public.save_cast_member_atomic(
  p_cast_member_id uuid,
  p_name text,
  p_role text,
  p_image_path text,
  p_image_position integer,
  p_custom_appearance_points integer,
  p_role_detail text,
  p_is_hough boolean,
  p_partner_id uuid,
  p_partnership_name text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_member_id uuid;
  v_pair_role text;
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'A cast member name is required.'; end if;
  if p_role not in ('Star','Pro','Eliminated Star','Eliminated Pro','Troupe','DWTS Next Pro','Judges + Hosts','Surprise') then raise exception 'Choose a valid cast role.'; end if;
  if p_image_position is null or p_image_position < 0 or p_image_position > 100 then raise exception 'Portrait position must be from 0 to 100.'; end if;
  if p_role = 'Surprise' and (p_custom_appearance_points is null or p_custom_appearance_points < 0) then raise exception 'Set a non-negative Surprise appearance rate.'; end if;
  if p_role = 'Judges + Hosts' and p_role_detail not in ('Judge','Host','Judge + Host') then raise exception 'Choose Judge, Host, or Judge + Host.'; end if;

  if p_cast_member_id is null then
    insert into public.cast_members (name,role,image_path,image_position,custom_appearance_points,role_detail,is_hough)
    values (trim(p_name),p_role,p_image_path,p_image_position,case when p_role='Surprise' then p_custom_appearance_points else null end,
      case when p_role='Judges + Hosts' then p_role_detail else null end,
      p_role='Judges + Hosts' and coalesce(p_is_hough,false)) returning id into v_member_id;
  else
    update public.cast_members set name=trim(p_name), role=p_role, image_path=p_image_path, image_position=p_image_position,
      custom_appearance_points=case when p_role='Surprise' then p_custom_appearance_points else null end,
      role_detail=case when p_role='Judges + Hosts' then p_role_detail else null end,
      is_hough=p_role='Judges + Hosts' and coalesce(p_is_hough,false)
    where id=p_cast_member_id returning id into v_member_id;
    if v_member_id is null then raise exception 'Cast member not found.'; end if;
  end if;

  v_pair_role := case when p_role in ('Star','Eliminated Star') then 'Star' when p_role in ('Pro','Eliminated Pro') then 'Pro' else 'Star' end;
  perform public.set_cast_partnership_atomic(v_member_id, v_pair_role,
    case when p_role in ('Star','Pro','Eliminated Star','Eliminated Pro') then p_partner_id else null end,
    case when p_role in ('Star','Pro','Eliminated Star','Eliminated Pro') then p_partnership_name else null end);
  return v_member_id;
end;
$$;

-- Refuse destructive deletion when a cast member is part of scored history.
create or replace function public.delete_cast_member_atomic(p_cast_member_id uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  perform 1 from public.cast_members where id = p_cast_member_id for update;
  if not found then raise exception 'Cast member not found.'; end if;
  if exists (select 1 from public.weekly_roster_snapshots where cast_member_id = p_cast_member_id)
     or exists (select 1 from public.dance_appearances where cast_member_id = p_cast_member_id)
     or exists (
       select 1 from public.dances d join public.partnerships p on p.id = d.partnership_id
       where p_cast_member_id in (p.star_id, p.pro_id)
     ) then
    raise exception 'This cast member is part of league history and cannot be deleted. Keep the record and update its assignment instead.';
  end if;
  delete from public.partnerships where p_cast_member_id in (star_id, pro_id);
  delete from public.cast_members where id = p_cast_member_id;
end;
$$;

create or replace function public.update_team_profile_atomic(
  p_team_id uuid,
  p_team_name text,
  p_manager_user_id uuid default null,
  p_first_name text default null,
  p_last_name text default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if not exists (select 1 from public.fantasy_teams where id = p_team_id for update) then raise exception 'Fantasy team not found.'; end if;
  if p_manager_user_id is not null and (nullif(trim(p_first_name), '') is null or nullif(trim(p_last_name), '') is null) then
    raise exception 'First and last name are required.';
  end if;
  update public.fantasy_teams set team_name = nullif(trim(p_team_name), '') where id = p_team_id;
  if p_manager_user_id is not null then
    update public.league_members set first_name = trim(p_first_name), last_name = trim(p_last_name), updated_at = now()
    where user_id = p_manager_user_id and fantasy_team_id = p_team_id;
    if not found then raise exception 'The selected manager is not connected to this fantasy team.'; end if;
  end if;
end;
$$;

create or replace function public.update_role_rates_atomic(p_rates jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare v_rate jsonb;
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  if jsonb_typeof(p_rates) is distinct from 'array' then raise exception 'Role rates must be a list.'; end if;
  for v_rate in select value from jsonb_array_elements(p_rates) loop
    if coalesce(v_rate->>'name', '') = 'Surprise' then raise exception 'Surprise rates are set per cast member.'; end if;
    if coalesce(v_rate->>'appearance_points', '') !~ '^[0-9]{1,2}$' then raise exception 'Every rate must be a whole number from 0 to 99.'; end if;
    update public.roles set appearance_points = (v_rate->>'appearance_points')::integer where name = v_rate->>'name';
    if not found then raise exception 'Unknown role: %.', coalesce(v_rate->>'name', '(blank)'); end if;
  end loop;
end;
$$;

-- Preserve a truly optional title while continuing to update setup and order atomically.
create or replace function public.update_week_setup_and_order(
  p_week_id uuid,
  p_theme text,
  p_title text,
  p_guest_judge_name text,
  p_double_elimination boolean,
  p_is_finale boolean,
  p_dance_ids uuid[]
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_week public.weeks%rowtype;
  v_ids uuid[] := coalesce(p_dance_ids, '{}'::uuid[]);
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if v_week.is_complete then raise exception 'A completed week’s setup cannot be edited.'; end if;
  if cardinality(v_ids) <> (select count(*) from public.dances where week_id = p_week_id)
     or cardinality(v_ids) <> (select count(distinct id) from unnest(v_ids) as id)
     or exists (select 1 from unnest(v_ids) as id where not exists (select 1 from public.dances where week_id = p_week_id and public.dances.id = id)) then
    raise exception 'The dance list changed. Reload this week and try again.';
  end if;
  if p_guest_judge_name is not null and nullif(trim(p_guest_judge_name), '') is null then raise exception 'Enter a guest judge name or turn off the guest judge option.'; end if;
  if p_guest_judge_name is not null and lower(trim(p_guest_judge_name)) = any(array['carrie ann','derek','bruno']::text[]) then raise exception 'The guest judge name must differ from the regular judges.'; end if;
  if exists (
    select 1 from public.dance_judge_scores s join public.dances d on d.id = s.dance_id
    where d.week_id = p_week_id and d.kind = 'competitive'
      and not (s.judge_name = any(array['Carrie Ann','Derek','Bruno']::text[] ||
        case when nullif(trim(p_guest_judge_name), '') is null then '{}'::text[] else array[trim(p_guest_judge_name)] end))
  ) then raise exception 'Existing scores use a different guest judge. Edit those dances first.'; end if;
  update public.weeks set theme = nullif(trim(p_theme), ''), title = nullif(trim(p_title), ''),
    guest_judge_name = nullif(trim(p_guest_judge_name), ''),
    double_elimination = case when p_is_finale then false else p_double_elimination end,
    is_finale = p_is_finale where id = p_week_id;
  update public.dances d set sort_order = ordered.ordinal::integer
  from unnest(v_ids) with ordinality as ordered(id, ordinal)
  where d.id = ordered.id and d.week_id = p_week_id;
end;
$$;

-- Replace only the completed-week gate and commissioner check in the existing
-- atomic dance function. All score, judge, duplicate, and cast validations remain.
create or replace function public.save_dance_atomic(
  p_week_id uuid, p_dance_id uuid, p_kind text, p_partnership_id uuid,
  p_name text, p_dance_type text, p_song text, p_judge_scores jsonb,
  p_cast_member_ids uuid[], p_scores_only boolean
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_week public.weeks%rowtype; v_dance public.dances%rowtype; v_dance_id uuid;
  v_score jsonb; v_judge_name text; v_expected_judges text[];
  v_cast_ids uuid[] := coalesce(p_cast_member_ids, '{}'::uuid[]);
begin
  if not public.is_league_commissioner() then raise exception 'Commissioner access is required.'; end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if p_dance_id is not null then
    select * into v_dance from public.dances where id = p_dance_id and week_id = p_week_id for update;
    if not found then raise exception 'Dance not found in this week.'; end if;
  end if;
  if v_week.is_complete and not (
    (coalesce(p_scores_only, false) and p_dance_id is not null) or
    (p_dance_id is null and p_kind = 'performance' and not coalesce(p_scores_only, false))
  ) then raise exception 'Use the Week Ledger to correct a completed week.'; end if;
  if p_scores_only and (p_dance_id is null or v_dance.kind <> 'competitive') then raise exception 'Only an existing competitive dance supports score-only edits.'; end if;
  if p_scores_only then p_kind := v_dance.kind; end if;
  if p_kind is null or p_kind not in ('competitive','performance') then raise exception 'Choose a valid dance type.'; end if;
  if p_kind = 'competitive' and (case when p_scores_only then v_dance.partnership_id else p_partnership_id end) is null then raise exception 'A competitive dance needs a couple.'; end if;
  if p_kind = 'performance' and p_partnership_id is not null then raise exception 'A performance cannot have a competing couple.'; end if;
  if jsonb_typeof(p_judge_scores) is distinct from 'array' then raise exception 'Judge scores must be a list.'; end if;
  if p_kind = 'performance' and jsonb_array_length(p_judge_scores) > 0 then raise exception 'A performance cannot have judge scores.'; end if;
  if (select count(*) from unnest(v_cast_ids) m(member_id)) <> (select count(distinct member_id) from unnest(v_cast_ids) m(member_id)) then raise exception 'A cast member can appear only once in a dance.'; end if;
  v_expected_judges := array['Carrie Ann','Derek','Bruno']::text[];
  if nullif(trim(v_week.guest_judge_name), '') is not null then v_expected_judges := array_append(v_expected_judges, v_week.guest_judge_name); end if;
  for v_score in select item from jsonb_array_elements(p_judge_scores) scores(item) loop
    v_judge_name := v_score->>'judge_name';
    if v_judge_name is null or not (v_judge_name = any(v_expected_judges)) then raise exception 'Unrecognized judge: %.', coalesce(v_judge_name, '(blank)'); end if;
    if coalesce(v_score->>'score', '') !~ '^(10|[0-9])$' then raise exception 'Each judge score must be a whole number from 0 to 10.'; end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_judge_scores)) <> (select count(distinct item->>'judge_name') from jsonb_array_elements(p_judge_scores) scores(item)) then raise exception 'Each judge can score a dance only once.'; end if;
  if p_dance_id is null then
    insert into public.dances (week_id,kind,partnership_id,name,dance_type,song,sort_order)
    values (p_week_id,p_kind,p_partnership_id,nullif(trim(p_name),''),nullif(trim(p_dance_type),''),nullif(trim(p_song),''),coalesce((select max(sort_order)+1 from public.dances where week_id=p_week_id),1))
    returning id into v_dance_id;
  else
    v_dance_id := p_dance_id;
    if not p_scores_only then update public.dances set kind=p_kind, partnership_id=p_partnership_id, name=nullif(trim(p_name),''), dance_type=nullif(trim(p_dance_type),''), song=nullif(trim(p_song),'') where id=v_dance_id; end if;
  end if;
  delete from public.dance_judge_scores where dance_id=v_dance_id;
  insert into public.dance_judge_scores (dance_id,judge_name,score)
  select v_dance_id,item->>'judge_name',(item->>'score')::integer from jsonb_array_elements(p_judge_scores) scores(item);
  if not p_scores_only then
    delete from public.dance_appearances where dance_id=v_dance_id;
    insert into public.dance_appearances (dance_id,cast_member_id) select v_dance_id,member_id from unnest(v_cast_ids) m(member_id);
  end if;
  return v_dance_id;
end;
$$;

revoke all on function public.set_cast_partnership_atomic(uuid,text,uuid,text) from public, anon;
grant execute on function public.set_cast_partnership_atomic(uuid,text,uuid,text) to authenticated;
revoke all on function public.save_cast_member_atomic(uuid,text,text,text,integer,integer,text,boolean,uuid,text) from public, anon;
grant execute on function public.save_cast_member_atomic(uuid,text,text,text,integer,integer,text,boolean,uuid,text) to authenticated;
revoke all on function public.delete_cast_member_atomic(uuid) from public, anon;
grant execute on function public.delete_cast_member_atomic(uuid) to authenticated;
revoke all on function public.update_team_profile_atomic(uuid,text,uuid,text,text) from public, anon;
grant execute on function public.update_team_profile_atomic(uuid,text,uuid,text,text) to authenticated;
revoke all on function public.update_role_rates_atomic(jsonb) from public, anon;
grant execute on function public.update_role_rates_atomic(jsonb) to authenticated;

commit;
notify pgrst, 'reload schema';
