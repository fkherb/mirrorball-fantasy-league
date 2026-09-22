-- Run once in Supabase Dashboard → SQL Editor before using the new Score Desk
-- save and reorder controls. This changes no existing dances or scores.

begin;

create or replace function public.save_dance_atomic(
  p_week_id uuid,
  p_dance_id uuid,
  p_kind text,
  p_partnership_id uuid,
  p_name text,
  p_dance_type text,
  p_song text,
  p_judge_scores jsonb,
  p_cast_member_ids uuid[],
  p_scores_only boolean
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_week public.weeks%rowtype;
  v_dance public.dances%rowtype;
  v_dance_id uuid;
  v_score jsonb;
  v_judge_name text;
  v_expected_judges text[];
  v_cast_ids uuid[] := coalesce(p_cast_member_ids, '{}'::uuid[]);
begin
  if (auth.jwt() ->> 'email') is distinct from 'herbfreddy@gmail.com' then
    raise exception 'Commissioner access is required.';
  end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;

  if p_dance_id is not null then
    select * into v_dance from public.dances where id = p_dance_id and week_id = p_week_id for update;
    if not found then raise exception 'Dance not found in this week.'; end if;
  end if;
  if v_week.is_complete and (not coalesce(p_scores_only, false) or p_dance_id is null) then
    raise exception 'Use the Week Ledger to correct a completed week.';
  end if;
  if p_scores_only and (p_dance_id is null or v_dance.kind <> 'competitive') then
    raise exception 'Only an existing competitive dance supports score-only edits.';
  end if;
  if p_scores_only then
    p_kind := v_dance.kind;
  end if;
  if p_kind is null or p_kind not in ('competitive', 'performance') then
    raise exception 'Choose a valid dance type.';
  end if;
  if p_kind = 'competitive' and (case when p_scores_only then v_dance.partnership_id else p_partnership_id end) is null then
    raise exception 'A competitive dance needs a couple.';
  end if;
  if p_kind = 'performance' and p_partnership_id is not null then
    raise exception 'A performance cannot have a competing couple.';
  end if;
  if jsonb_typeof(p_judge_scores) is distinct from 'array' then
    raise exception 'Judge scores must be a list.';
  end if;
  if p_kind = 'performance' and jsonb_array_length(p_judge_scores) > 0 then
    raise exception 'A performance cannot have judge scores.';
  end if;
  if (select count(*) from unnest(v_cast_ids) as members(member_id)) <>
     (select count(distinct member_id) from unnest(v_cast_ids) as members(member_id)) then
    raise exception 'A cast member can appear only once in a dance.';
  end if;

  v_expected_judges := array['Carrie Ann', 'Derek', 'Bruno']::text[];
  if nullif(trim(v_week.guest_judge_name), '') is not null then
    v_expected_judges := array_append(v_expected_judges, v_week.guest_judge_name);
  end if;
  if array_length(v_expected_judges, 1) <>
     (select count(distinct judge_name) from unnest(v_expected_judges) as judge_name) then
    raise exception 'The guest judge name must differ from the regular judges.';
  end if;
  for v_score in select item from jsonb_array_elements(p_judge_scores) as scores(item) loop
    v_judge_name := v_score->>'judge_name';
    if v_judge_name is null or not (v_judge_name = any(v_expected_judges)) then
      raise exception 'Unrecognized judge: %.', coalesce(v_judge_name, '(blank)');
    end if;
    if coalesce(v_score->>'score', '') !~ '^(10|[0-9])$' then
      raise exception 'Each judge score must be a whole number from 0 to 10.';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_judge_scores)) <>
     (select count(distinct item->>'judge_name') from jsonb_array_elements(p_judge_scores) as scores(item)) then
    raise exception 'Each judge can score a dance only once.';
  end if;

  if p_dance_id is null then
    insert into public.dances (week_id, kind, partnership_id, name, dance_type, song, sort_order)
    values (p_week_id, p_kind, p_partnership_id, p_name, p_dance_type, p_song,
      coalesce((select max(sort_order) + 1 from public.dances where week_id = p_week_id), 1))
    returning id into v_dance_id;
  else
    v_dance_id := p_dance_id;
    if not p_scores_only then
      update public.dances set kind = p_kind, partnership_id = p_partnership_id,
        name = p_name, dance_type = p_dance_type, song = p_song where id = v_dance_id;
    end if;
  end if;

  delete from public.dance_judge_scores where dance_id = v_dance_id;
  insert into public.dance_judge_scores (dance_id, judge_name, score)
  select v_dance_id, item->>'judge_name', (item->>'score')::integer
  from jsonb_array_elements(p_judge_scores) as scores(item);

  if not p_scores_only then
    delete from public.dance_appearances where dance_id = v_dance_id;
  insert into public.dance_appearances (dance_id, cast_member_id)
    select v_dance_id, member_id from unnest(v_cast_ids) as members(member_id);
  end if;
  return v_dance_id;
end;
$$;

revoke all on function public.save_dance_atomic(uuid,uuid,text,uuid,text,text,text,jsonb,uuid[],boolean) from public, anon;
grant execute on function public.save_dance_atomic(uuid,uuid,text,uuid,text,text,text,jsonb,uuid[],boolean) to authenticated;

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
  if (auth.jwt() ->> 'email') is distinct from 'herbfreddy@gmail.com' then
    raise exception 'Commissioner access is required.';
  end if;
  select * into v_week from public.weeks where id = p_week_id for update;
  if not found then raise exception 'Week not found.'; end if;
  if v_week.is_complete then raise exception 'A completed week’s setup cannot be edited.'; end if;
  if cardinality(v_ids) <> (select count(*) from public.dances where week_id = p_week_id)
     or cardinality(v_ids) <> (select count(distinct id) from unnest(v_ids) as id)
     or exists (select 1 from unnest(v_ids) as id
                where not exists (select 1 from public.dances where week_id = p_week_id and public.dances.id = id)) then
    raise exception 'The dance list changed. Reload this week and try again.';
  end if;
  if p_guest_judge_name is not null and nullif(trim(p_guest_judge_name), '') is null then
    raise exception 'Enter a guest judge name or turn off the guest judge option.';
  end if;
  if p_guest_judge_name is not null and p_guest_judge_name = any(array['Carrie Ann','Derek','Bruno']::text[]) then
    raise exception 'The guest judge name must differ from the regular judges.';
  end if;
  if exists (
    select 1 from public.dance_judge_scores as s
    join public.dances as d on d.id = s.dance_id
    where d.week_id = p_week_id and d.kind = 'competitive'
      and not (s.judge_name = any(array['Carrie Ann','Derek','Bruno']::text[] ||
        case when nullif(trim(p_guest_judge_name), '') is null then '{}'::text[]
             else array[trim(p_guest_judge_name)] end))
  ) then
    raise exception 'Existing scores use a different guest judge. Edit those dances first.';
  end if;
  update public.weeks set theme = nullif(trim(p_theme), ''),
    title = coalesce(nullif(trim(p_title), ''),
      case when nullif(trim(p_theme), '') is null then 'Week ' || v_week.number
           else trim(p_theme) || ' Week' end),
    guest_judge_name = nullif(trim(p_guest_judge_name), ''),
    double_elimination = case when p_is_finale then false else p_double_elimination end,
    is_finale = p_is_finale
  where id = p_week_id;
  update public.dances as d set sort_order = ordered.ordinal::integer
  from unnest(v_ids) with ordinality as ordered(id, ordinal)
  where d.id = ordered.id and d.week_id = p_week_id;
end;
$$;

revoke all on function public.update_week_setup_and_order(uuid,text,text,text,boolean,boolean,uuid[]) from public, anon;
grant execute on function public.update_week_setup_and_order(uuid,text,text,text,boolean,boolean,uuid[]) to authenticated;

commit;
