-- TEST ONLY: run after fixture + both migrations in an isolated database.
create function pg_temp.check_true(condition boolean,message text) returns void language plpgsql as $$ begin
  if condition is distinct from true then raise exception 'TEST FAILED: %',message; end if;
end $$;
create function pg_temp.claim(mode text) returns jsonb language plpgsql as $$ begin
  perform public.configure_dwts_automation(4,true,array[mode]);
  return public.claim_dwts_work('test-server');
end $$;
create function pg_temp.wiki(mode text,performance jsonb) returns jsonb language plpgsql as $$
declare task jsonb; output jsonb;
begin
  task:=pg_temp.claim(mode);
  perform pg_temp.check_true(task->>'run_id' is not null,'job claimed for '||mode);
  select jsonb_agg(jsonb_build_object('star_name',t->>'star_name','pro_name',t->>'pro_name','found',true,'performances',jsonb_build_array(performance))) into output from jsonb_array_elements(task->'targets') t;
  return public.report_dwts_work('test-server',(task->>'run_id')::uuid,jsonb_build_object('mode',mode,'week',4,'week_tag',task->>'week_tag','couples',output));
end $$;
do $$ declare task jsonb; result jsonb; tag jsonb; d uuid; w uuid; pair uuid; run uuid; summary jsonb;
begin
  perform pg_temp.check_true(not exists(select 1 from public.dwts_automation_weeks where enabled),'disabled by default');
  perform pg_temp.check_true(public.claim_dwts_work('test-server')->>'run_id' is null,'disabled claim empty');
  perform pg_temp.check_true((select count(*)=2 from public.dances d join public.weeks w on w.id=d.week_id where w.number=3 and d.photos_uploaded),'old couples photo-complete');
  perform pg_temp.check_true(not exists(select 1 from public.dances where kind='performance' and photos_uploaded),'performances untouched');
  tag:='{"weeks":[{"week":4,"week_tag":"#Week_4:_Mariah_Carey_Night"}]}'::jsonb;
  task:=pg_temp.claim('get-weeks'); run:=(task->>'run_id')::uuid;
  result:=public.report_dwts_work('test-server',run,tag);
  perform pg_temp.check_true((select wiki_tag is null and wiki_tag_checks=1 from public.dwts_automation_weeks a join public.weeks w on w.id=a.week_id where w.number=4),'tag needs two checks');
  result:=public.report_dwts_work('test-server',run,tag);
  perform pg_temp.check_true((result->>'already_reported')::boolean,'duplicate report idempotent');
  task:=pg_temp.claim('get-weeks');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,tag);
  perform pg_temp.check_true((select wiki_tag is not null and wiki_tag_checks=2 from public.dwts_automation_weeks a join public.weeks w on w.id=a.week_id where w.number=4),'second tag confirmed');
  result:=pg_temp.wiki('pre-show','{"dance":"Rumba","song":"Wrong title","artist":null}');
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'first pre-show report valid');
  perform pg_temp.check_true((select count(*)=2 from public.dances d join public.weeks w on w.id=d.week_id where w.number=4 and d.song='Wrong title' and not d.song_confirmed),'provisional data visible but unconfirmed');
  result:=pg_temp.wiki('pre-show','{"dance":"Rumba","song":"Hero","artist":null}');
  perform pg_temp.check_true((select count(*)=2 from public.dances d join public.weeks w on w.id=d.week_id where w.number=4 and d.dance_type_confirmed and d.song='Hero' and not d.song_confirmed),'changed song reset independently');
  result:=pg_temp.wiki('pre-show','{"dance":"Rumba","song":"Hero","artist":null}');
  perform pg_temp.check_true((select count(*)=2 from public.dances d join public.weeks w on w.id=d.week_id where w.number=4 and d.song_confirmed),'blank artists permit confirmation');
  perform pg_temp.check_true(jsonb_array_length(public.dwts_pending_targets((select id from public.weeks where number=4),'pre-show'))=0,'confirmed couples removed');
  result:=pg_temp.wiki('live-show','{"scores":[8,8,8],"total":24}');
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'live first valid');
  perform pg_temp.check_true((select count(*)=6 from public.dance_judge_scores where not confirmed),'scores provisional');
  result:=pg_temp.wiki('live-show','{"scores":[8,7,8],"total":23}');
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'live correction valid');
  result:=pg_temp.wiki('live-show','{"scores":[8,7,8],"total":23}');
  perform pg_temp.check_true((select count(*)=2 from public.dances d join public.weeks w on w.id=d.week_id where w.number=4 and d.scores_confirmed),'corrected scores confirmed after two');
  result:=pg_temp.wiki('post-show','{"eliminated":false}');
  result:=pg_temp.wiki('post-show','{"eliminated":false}');
  perform pg_temp.check_true((select count(*)=2 from public.dances d join public.weeks w on w.id=d.week_id where w.number=4 and d.elimination_confirmed and not d.elimination_result),'non-eliminated outcome confirmed');
  perform pg_temp.check_true(not (select is_complete from public.weeks where number=4),'no automatic week completion');
  select d.id,d.week_id,d.partnership_id into d,w,pair from public.dances d join public.weeks w on w.id=d.week_id where w.number=4 and d.kind='competitive' limit 1;
  -- Manual entries while a job is outstanding cannot be overwritten.
  update public.dances set song=null,song_confirmed=false where id=d;
  task:=pg_temp.claim('pre-show');
  update public.dances set song='Manual song by Manual Artist' where id=d;
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,jsonb_build_object('mode','pre-show','week',4,'week_tag',task->>'week_tag','couples',jsonb_build_array(jsonb_build_object('star_name',task->'targets'->0->>'star_name','pro_name',task->'targets'->0->>'pro_name','found',true,'performances','[{"dance":"Jive","song":"Overwrite","artist":null}]'::jsonb))));
  perform pg_temp.check_true((select song='Manual song by Manual Artist' and song_confirmed from public.dances where id=d),'manual edit protected');
  task:=pg_temp.claim('photos');
  perform pg_temp.check_true(task->>'run_id' is not null,'photo window eligible');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,'{"week":4,"dry_run":false,"failed_run":true,"skip_next_run":true,"uploaded_couples":[],"errors":[{"service":"X","cooldown_seconds":655}]}'::jsonb);
  perform pg_temp.check_true((select photos_not_before>=now()+interval '655 seconds' from public.dwts_automation_state),'X cooldown honored');
  task:=pg_temp.claim('photos');
  perform pg_temp.check_true(task->>'run_id' is null,'photo cooldown prevents claim');
  update public.dwts_automation_state set photos_not_before=null;
  task:=pg_temp.claim('photos');
  result:=public.report_dwts_work('test-server',(task->>'run_id')::uuid,jsonb_build_object('week',4,'dry_run',false,'uploaded_couples',jsonb_build_array(jsonb_build_object('star_name',task->'targets'->0->>'star_name','pro_name',task->'targets'->0->>'pro_name','files',jsonb_build_array(jsonb_build_object('path','Images/Dances/Week 4/'||(task->'targets'->0->>'star_name')||' and '||(task->'targets'->0->>'pro_name')||'-1.jpeg')),'post_ids',jsonb_build_array('123456789'),'commit_sha',repeat('a',40)))));
  perform pg_temp.check_true(jsonb_array_length(result->'errors')=0,'valid upload receipt accepted');
  perform pg_temp.check_true(jsonb_array_length(public.dwts_pending_targets(w,'photos'))=1,'uploaded couple removed');
  perform pg_temp.check_true((select count(*)=1 from public.dwts_photo_receipts),'post stored for dedupe');
  update public.weeks set is_complete=true where number=4;
  perform pg_temp.check_true(not exists(select 1 from public.dances where kind='competitive' and not photos_uploaded),'completion ends photo tracking');
end $$;
select 'PASS: disabled defaults, per-mode couples, changed values, two checks, idempotency, manual protection, scores, elimination, X cooldown, receipts, completion' as tests;
