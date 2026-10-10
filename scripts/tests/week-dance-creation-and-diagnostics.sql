-- TEST ONLY: isolated database, run by check-week-automation-db.mjs.
create function pg_temp.check_true(condition boolean,message text) returns void language plpgsql as $$ begin
  if condition is distinct from true then raise exception 'TEST FAILED: %',message; end if;
end $$;
do $$ declare task jsonb;result jsonb;payload jsonb;w uuid;first_dance uuid; begin
  select id into w from public.weeks where number=5;
  task:=public.claim_dwts_work('test-server');
  perform pg_temp.check_true(task->>'mode'='pre-show' and jsonb_array_length(task->'targets')=11,'Week 5 worker gets all 11 couples');
  first_dance:=(task->'targets'->0->>'dance_id')::uuid;
  payload:=jsonb_build_object('mode','pre-show','week',5,'week_tag',task->>'week_tag','couples',
    (select jsonb_agg(jsonb_build_object('star_name',t->>'star_name','pro_name',t->>'pro_name','found',true,
      'performances','[{"dance":"Rumba","song":"First Song","artist":"Artist"}]'::jsonb)) from jsonb_array_elements(task->'targets') t));
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true((select count(*)=11 from public.dances where week_id=w and dance_type='Rumba'
    and song='First Song by Artist' and not dance_type_confirmed and not song_confirmed),'first observation visible immediately');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true((result->>'already_reported')::boolean,'duplicate run idempotent');
  perform pg_temp.check_true((select not song_confirmed from public.dances where id=first_dance),'duplicate is not second observation');
  perform public.configure_dwts_automation(5,true,array['pre-show']);
  task:=public.claim_dwts_work('test-server');
  payload:=jsonb_set(payload,'{couples,0,performances,0,song}','"Corrected Song"');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true((select count(*)=10 from public.dances where week_id=w and dance_type_confirmed and song_confirmed),'matching couples confirmed');
  perform pg_temp.check_true((select song='Corrected Song by Artist' and not song_confirmed from public.dances where id=first_dance),'changed value visible and count reset');
  perform public.configure_dwts_automation(5,true,array['pre-show']);
  task:=public.claim_dwts_work('test-server');
  perform pg_temp.check_true(jsonb_array_length(task->'targets')=1,'already confirmed couples not sent again');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true(jsonb_array_length(public.dwts_pending_targets(w,'pre-show'))=0,'second corrected observation removes final couple');
  perform public.configure_dwts_automation(5,true,array['pre-show']);
  perform pg_temp.check_true(public.claim_dwts_work('test-server')->>'run_id' is null,'no more pre-show jobs after confirmation');

  perform public.configure_dwts_automation(5,true,array['live-show']);
  task:=public.claim_dwts_work('test-server');
  payload:=jsonb_build_object('mode','live-show','week',5,'week_tag',task->>'week_tag','couples',
    (select jsonb_agg(jsonb_build_object('star_name',t->>'star_name','pro_name',t->>'pro_name','found',true,
      'performances','[{"scores":null,"total":null}]'::jsonb)) from jsonb_array_elements(task->'targets') t));
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'null score arrays never crash ordering wrapper');
  perform public.configure_dwts_automation(5,true,array['live-show']);task:=public.claim_dwts_work('test-server');
  payload:=jsonb_set(payload,'{couples}',(select jsonb_agg(jsonb_build_object('star_name',t->>'star_name','pro_name',t->>'pro_name','found',true,
    'performances','[{"scores":[8,8,8],"total":24,"table_index":0,"row_index":2}]'::jsonb)) from jsonb_array_elements(task->'targets') t));
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true((select count(*)=33 from public.dance_judge_scores s join public.dances d on d.id=s.dance_id where d.week_id=w and not s.confirmed),'first scores visible but unconfirmed');
  perform pg_temp.check_true((select count(*)=11 from public.dances where week_id=w and wiki_score_sequence is not null),'score order still applied');
  perform public.configure_dwts_automation(5,true,array['live-show']);task:=public.claim_dwts_work('test-server');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,payload);
  perform pg_temp.check_true(jsonb_array_length(public.dwts_pending_targets(w,'live-show'))=0,'two matching score runs removed');

  perform public.configure_dwts_automation(5,true,array['photos']);task:=public.claim_dwts_work('test-server');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,
    '{"week":5,"dry_run":false,"uploaded_couples":[],"diagnostics":{"version":1,"outcome":"no_images_downloaded","matched_posts":3,"empty_downloads":3}}');
  perform pg_temp.check_true(result->'photo_diagnostics'->>'outcome'='no_images_downloaded','diagnostics returned');
  perform pg_temp.check_true((select summary->'photo_diagnostics'->>'matched_posts'='3' from public.dwts_automation_runs where id=(task->>'run_id')::uuid),'diagnostics stored');
  perform pg_temp.check_true(not exists(select 1 from public.dances where week_id=w and photos_uploaded),'empty download never counts as uploaded');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,'{"week":5,"diagnostics":{"outcome":"uploaded"}}');
  perform pg_temp.check_true(result->'photo_diagnostics'->>'outcome'='no_images_downloaded','repeat cannot rewrite diagnostics');
  perform pg_temp.check_true(not has_function_privilege('authenticated','public.ensure_week_competitive_dances(uuid)','execute'),'private creation helper inaccessible');
  perform pg_temp.check_true(not has_function_privilege('anon','public.prepare_week_competitive_dances(uuid)','execute'),'anonymous repair forbidden');
  perform pg_temp.check_true(not has_function_privilege('service_role','public.report_dwts_work_before_photo_diagnostics(text,uuid,jsonb)','execute'),'backend cannot bypass wrapper');
  perform set_config('test.owner','no',true);
  begin
    perform public.prepare_week_competitive_dances(w);
    raise exception 'TEST FAILED: non-owner repair accepted';
  exception when others then
    if sqlerrm not like '%Platform-owner%' then raise; end if;
  end;
  perform set_config('test.owner','yes',true);
end $$;

-- Simulate iOS updating completion FIRST, eliminating a couple LATER in the
-- same transaction. Only ten surviving couples belong in Week 6.
begin;
update public.weeks set is_complete=true where number=5;
update public.cast_members set role='Eliminated Star',eliminated_week_id=(select id from public.weeks where number=5) where name='Amber Glenn';
update public.cast_members set role='Eliminated Pro',eliminated_week_id=(select id from public.weeks where number=5) where name='Pasha Pashkov';
commit;
select pg_temp.check_true((select count(*)=10 from public.dances d join public.weeks w on w.id=d.week_id where w.number=6),'transaction-end generation excludes newly eliminated couple');
select pg_temp.check_true((select not exists(select 1 from public.dances d join public.partnerships p on p.id=d.partnership_id
  join public.cast_members s on s.id=p.star_id join public.weeks w on w.id=d.week_id where w.number=6 and s.name='Amber Glenn')),'stale active partnership excluded');

-- Creation when the next week is added AFTER completion, and finale cutoff.
update public.weeks set is_complete=true where number=6;
insert into public.weeks(number) values(7);
select pg_temp.check_true((select count(*)=10 from public.dances d join public.weeks w on w.id=d.week_id where w.number=7),'new next-week insertion also seeds cards');
update public.weeks set is_season_finale=true,is_complete=true where number=7;
insert into public.weeks(number) values(8);
select pg_temp.check_true((select count(*)=0 from public.dances d join public.weeks w on w.id=d.week_id where w.number=8),'season finale stops seeding');
