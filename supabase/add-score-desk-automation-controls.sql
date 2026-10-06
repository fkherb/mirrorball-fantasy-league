-- Run after automation functions + worker support. No jobs are enabled here.
begin;
alter table public.dwts_automation_weeks add column if not exists wiki_tag_override boolean not null default false;

create or replace function public.save_week_with_automation(p_setup jsonb,p_automation jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare w public.weeks%rowtype; a public.dwts_automation_weeks%rowtype;
  modes text[]; judges text[]; expected text[]; tag text; manual_tag boolean;
begin
  if not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access required'; end if;
  perform pg_advisory_xact_lock(2601005,1);
  select * into w from public.weeks where id=(p_setup->>'p_week_id')::uuid for update;
  if not found or w.is_complete then raise exception 'Only an incomplete week can be edited'; end if;
  if jsonb_typeof(p_automation->'modes') is distinct from 'array' then raise exception 'Select automation modes'; end if;
  modes:=array(select jsonb_array_elements_text(p_automation->'modes'));
  if modes is null or not modes <@ array['get-weeks','pre-show','live-show','post-show','photos']::text[] then raise exception 'Unknown automation mode'; end if;
  manual_tag:=coalesce((p_automation->>'wiki_tag_override')::boolean,false);
  tag:=nullif(btrim(p_automation->>'wiki_tag'),'');
  if manual_tag and (tag is null or length(tag)>250 or tag !~ '^#Week_[0-9]+:') then raise exception 'Enter a Wikipedia week tag such as #Week_4:_Mariah_Carey_Night'; end if;
  if manual_tag and substring(tag from '^#Week_([0-9]+):')::integer<>w.number then raise exception 'Wikipedia tag must match this week number'; end if;
  expected:=array['Carrie Ann','Derek','Bruno'];
  if nullif(btrim(p_setup->>'p_guest_judge_name'),'') is not null then expected:=expected||array[btrim(p_setup->>'p_guest_judge_name')]; end if;
  if jsonb_typeof(p_automation->'judge_order')='array' then
    judges:=array(select jsonb_array_elements_text(p_automation->'judge_order'));
  end if;
  if cardinality(judges)=0 then judges:=null; end if;
  if judges is not null and (cardinality(judges)<>cardinality(expected) or not judges @> expected or not judges <@ expected) then raise exception 'Judge order must contain every judge exactly once'; end if;
  if coalesce((p_automation->>'enabled')::boolean,false) and 'live-show'=any(modes) and cardinality(expected)=4 and judges is null then raise exception 'Select Wikipedia judge order for the guest judge'; end if;
  select * into a from public.dwts_automation_weeks where week_id=w.id;
  perform public.update_week_setup_with_market_schedule(
    w.id,p_setup->>'p_theme',p_setup->>'p_title',p_setup->>'p_guest_judge_name',
    (p_setup->>'p_double_elimination')::boolean,(p_setup->>'p_is_finale')::boolean,
    array(select jsonb_array_elements_text(p_setup->'p_dance_ids'))::uuid[],
    (p_setup->>'p_air_date')::date,(p_setup->>'p_second_air_date')::date,(p_setup->>'p_is_season_finale')::boolean,
    (p_setup->>'p_air_start_time')::time,(p_setup->>'p_air_end_time')::time,
    (p_setup->>'p_second_air_start_time')::time,(p_setup->>'p_second_air_end_time')::time,
    (p_setup->>'p_elimination_predictions_enabled')::boolean);
  perform public.configure_dwts_automation(w.number,coalesce((p_automation->>'enabled')::boolean,false),modes,judges);
  update public.dwts_automation_weeks set wiki_tag_override=manual_tag,
    wiki_tag=case when manual_tag then tag when a.wiki_tag_override then null else wiki_tag end,
    wiki_tag_candidate=case when manual_tag then tag when a.wiki_tag_override then null else wiki_tag_candidate end,
    wiki_tag_checks=case when manual_tag then 2 when a.wiki_tag_override then 0 else wiki_tag_checks end,
    wiki_tag_last_check=case when manual_tag or a.wiki_tag_override then null else wiki_tag_last_check end
  where week_id=w.id;
end $$;

create or replace function public.get_week_automation_status(p_week_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w public.weeks%rowtype; data jsonb;
begin
  if not coalesce(public.is_platform_admin(),false) then raise exception 'Platform-owner access required'; end if;
  select * into w from public.weeks where id=p_week_id;
  if not found then raise exception 'Week not found'; end if;
  select jsonb_build_object('settings',to_jsonb(a),'worker',to_jsonb(s), 'server_time',now(),
    'previous_complete',w.number=1 or exists(select 1 from public.weeks p where p.number=w.number-1 and p.is_complete),
    'progress',(select jsonb_build_object('total',count(*),
      'dance_types',count(*) filter(where dance_type_confirmed),'songs',count(*) filter(where song_confirmed),
      'scores',count(*) filter(where scores_confirmed),'eliminations',count(*) filter(where elimination_confirmed),
      'photos',count(*) filter(where photos_uploaded)) from public.dances where week_id=w.id and kind='competitive'),
    'jobs',coalesce((select jsonb_agg(jsonb_build_object('mode',j.mode,'next_run_at',j.next_run_at,
      'lease_until',j.lease_until,'last_error',j.last_error,'pending',jsonb_array_length(public.dwts_pending_targets(w.id,j.mode)),
      'window',case when j.mode in ('photos','live-show','post-show') then public.dwts_window_opening(w.id,j.mode,now()) else now() end,
      'elimination_found',exists(select 1 from public.dances d where d.week_id=w.id and d.elimination_confirmed and d.elimination_result),
      'last_run',to_jsonb(r))) from public.dwts_automation_jobs j
      left join lateral (select started_at,finished_at,status from public.dwts_automation_runs where job_id=j.id order by started_at desc limit 1) r on true
      where j.week_id=w.id),'[]'::jsonb)) into data
  from (select 1) seed left join public.dwts_automation_weeks a on a.week_id=w.id
    left join public.dwts_automation_state s on s.id=1;
  return data;
end $$;
revoke all on function public.save_week_with_automation(jsonb,jsonb),public.get_week_automation_status(uuid) from public,anon;
grant execute on function public.save_week_with_automation(jsonb,jsonb),public.get_week_automation_status(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
