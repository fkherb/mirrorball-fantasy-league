-- STEP 2: run AFTER add-dance-confirmation-tracking.sql.
-- Installs database scheduling/claim/report functions only. No external calls,
-- credentials, cron jobs, or website changes. Every week starts DISABLED.
-- Completed weeks' competitive photos are treated as done by owner request.
begin;

update public.dances d set photos_uploaded = true
from public.weeks w where w.id = d.week_id and w.is_complete
  and d.kind = 'competitive' and not d.photos_uploaded;

create table if not exists public.dwts_automation_weeks (
  week_id uuid primary key references public.weeks(id) on delete cascade,
  enabled boolean not null default false,
  inherit_previous boolean not null default true,
  modes text[] not null default array['get-weeks', 'pre-show']::text[]
    check (modes <@ array['get-weeks','pre-show','live-show','post-show','photos']::text[]),
  wiki_tag text,
  wiki_tag_candidate text,
  wiki_tag_checks integer not null default 0 check (wiki_tag_checks >= 0),
  wiki_tag_last_check uuid,
  judge_order text[],
  updated_at timestamptz not null default now()
);
insert into public.dwts_automation_weeks(week_id) select id from public.weeks
on conflict (week_id) do nothing;

create table if not exists public.dwts_automation_state (
  id integer primary key check (id = 1),
  photos_not_before timestamptz,
  last_heartbeat_at timestamptz,
  worker_name text
);
insert into public.dwts_automation_state(id) values (1) on conflict do nothing;

create table if not exists public.dwts_automation_jobs (
  id uuid primary key default gen_random_uuid(),
  week_id uuid not null references public.weeks(id) on delete cascade,
  mode text not null check (mode in ('get-weeks','pre-show','live-show','post-show','photos')),
  next_run_at timestamptz not null default now(),
  active_run_id uuid,
  lease_until timestamptz,
  last_error text,
  unique(week_id,mode)
);
create table if not exists public.dwts_automation_runs (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.dwts_automation_jobs(id) on delete cascade,
  worker_name text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running','finished','failed','expired')),
  payload jsonb not null,
  summary jsonb
);
create table if not exists public.dwts_photo_receipts (
  week_id uuid not null references public.weeks(id) on delete cascade,
  post_id text not null check (post_id ~ '^[0-9]{1,30}$'),
  partnership_id uuid not null references public.partnerships(id),
  files jsonb not null check (jsonb_typeof(files) = 'array' and jsonb_array_length(files) > 0),
  commit_sha text not null check (commit_sha ~ '^[0-9a-f]{40}$'),
  uploaded_at timestamptz not null default now(),
  primary key(week_id,post_id)
);

-- Admins may inspect state; mutations go through guarded RPCs. Workers will
-- authenticate at an Edge Function, which calls service-role-only RPCs below.
do $$ declare t text; begin
  foreach t in array array['dwts_automation_weeks','dwts_automation_state',
    'dwts_automation_jobs','dwts_automation_runs','dwts_photo_receipts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('drop policy if exists "platform owner reads automation" on public.%I', t);
    execute format('create policy "platform owner reads automation" on public.%I for select to authenticated using (public.is_platform_admin())', t);
  end loop;
end $$;

-- Internal imports are not manual entries, even in owner-run SQL tests.
-- Keep previous manual trigger behavior but recognize a transaction-local
-- marker set ONLY by the protected report RPC. This also avoids clearing
-- candidate counters while an unconfirmed Wiki value is being updated.
create or replace function public.mark_manual_dance_details_confirmed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() = 'service_role' or current_setting('mirrorball.automation_import',true) = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    new.dance_type_confirmed := new.kind = 'competitive' and nullif(btrim(new.dance_type),'') is not null;
    new.song_confirmed := new.kind = 'competitive' and nullif(btrim(new.song),'') is not null;
    new.elimination_confirmed := new.kind = 'competitive' and new.elimination_result is not null;
  else
    if new.dance_type is distinct from old.dance_type or new.kind is distinct from old.kind then
      new.dance_type_confirmed := new.kind = 'competitive' and nullif(btrim(new.dance_type),'') is not null;
    end if;
    if new.song is distinct from old.song or new.kind is distinct from old.kind then
      new.song_confirmed := new.kind = 'competitive' and nullif(btrim(new.song),'') is not null;
    end if;
    if new.elimination_result is distinct from old.elimination_result or new.kind is distinct from old.kind then
      new.elimination_confirmed := new.kind = 'competitive' and new.elimination_result is not null;
    end if;
  end if;
  return new;
end $$;
create or replace function public.record_manual_dance_confirmation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare f text; present boolean; changed boolean;
begin
  if auth.role() = 'service_role' or current_setting('mirrorball.automation_import',true) = 'on' then return new; end if;
  foreach f in array array['dance_type','song','elimination_result'] loop
    changed := tg_op = 'INSERT';
    if tg_op = 'UPDATE' then changed := to_jsonb(new)->f is distinct from to_jsonb(old)->f or new.kind is distinct from old.kind; end if;
    if changed then
      present := new.kind = 'competitive' and nullif(btrim(to_jsonb(new)->>f),'') is not null;
      insert into public.dance_confirmation_checks(dance_id,field_name,confirmed_source,confirmed_at)
      values(new.id,case when f='elimination_result' then 'elimination' else f end,
        case when present then 'manual' end,case when present then now() end)
      on conflict(dance_id,field_name) do update set confirmed_source=excluded.confirmed_source,
        confirmed_at=excluded.confirmed_at,candidate_value=null,matching_checks=0,last_check_id=null,last_checked_at=null;
    end if;
  end loop;
  return new;
end $$;
create or replace function public.mark_manual_judge_score_confirmed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() = 'service_role' or current_setting('mirrorball.automation_import',true) = 'on' then return new; end if;
  if tg_op='INSERT' then new.confirmed:=true;
  elsif new.score is distinct from old.score or new.judge_name is distinct from old.judge_name or new.dance_id is distinct from old.dance_id then new.confirmed:=true;
  end if;
  return new;
end $$;
create or replace function public.track_judge_score_confirmation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare d uuid;
begin
  if tg_op='DELETE' then d:=old.dance_id; else d:=new.dance_id; end if;
  perform 1 from public.dances where id=d for update;
  perform public.refresh_dance_scores_confirmed(d);
  if auth.role() is distinct from 'service_role' and
    current_setting('mirrorball.automation_import',true) is distinct from 'on'
    and exists(select 1 from public.dances where id=d) then
    insert into public.dance_confirmation_checks(dance_id,field_name,confirmed_source,confirmed_at)
    values(d,'scores',case when tg_op<>'DELETE' then 'manual' end,case when tg_op<>'DELETE' then now() end)
    on conflict(dance_id,field_name) do update set confirmed_source=excluded.confirmed_source,
      confirmed_at=excluded.confirmed_at,candidate_value=null,matching_checks=0,last_check_id=null,last_checked_at=null;
  end if;
  if tg_op='UPDATE' and old.dance_id is distinct from new.dance_id then perform public.refresh_dance_scores_confirmed(old.dance_id); end if;
  return null;
end $$;

-- Confirmation is per field, not per HTTP request. A repeat report for the
-- SAME run never counts twice. Missing data resets the consecutive count.
create or replace function public.dwts_observe_field(p_dance uuid,p_field text,p_value jsonb,p_run uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare c public.dance_confirmation_checks%rowtype; n integer;
begin
  insert into public.dance_confirmation_checks(dance_id,field_name) values(p_dance,p_field) on conflict do nothing;
  select * into c from public.dance_confirmation_checks where dance_id=p_dance and field_name=p_field for update;
  if c.last_check_id=p_run then return c.matching_checks; end if;
  if p_value is null or p_value='null'::jsonb then n:=0;
  elsif c.candidate_value=p_value then n:=least(c.matching_checks+1,2);
  else n:=1; end if;
  update public.dance_confirmation_checks set candidate_value=p_value,matching_checks=n,
    last_check_id=p_run,last_checked_at=now(),confirmed_source=case when n=2 then 'wiki' end,
    confirmed_at=case when n=2 then now() end where dance_id=p_dance and field_name=p_field;
  return n;
end $$;

create or replace function public.dwts_pending_targets(p_week uuid,p_mode text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('dance_id',d.id,'partnership_id',p.id,
    'star_name',s.name,'pro_name',r.name) order by d.sort_order,d.id),'[]'::jsonb)
  from public.dances d join public.partnerships p on p.id=d.partnership_id
    join public.cast_members s on s.id=p.star_id join public.cast_members r on r.id=p.pro_id
  where d.week_id=p_week and d.kind='competitive' and case p_mode
    when 'pre-show' then not d.dance_type_confirmed or not d.song_confirmed
    when 'live-show' then not d.scores_confirmed
    when 'post-show' then not d.elimination_confirmed
    when 'photos' then not d.photos_uploaded else false end;
$$;

-- Returns the current or next permissible airing window opening. Expired
-- windows return NULL; missed live jobs are not replayed after the cutoff.
create or replace function public.dwts_window_opening(p_week uuid,p_mode text,p_now timestamptz)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select min(case when p_now>=x.opens then p_now else x.opens end)
  from public.weeks w cross join lateral (values
    (w.air_date,w.air_start_time,w.air_end_time),
    (w.second_air_date,coalesce(w.second_air_start_time,w.air_start_time),coalesce(w.second_air_end_time,w.air_end_time))
  ) a(day,starts,ends) cross join lateral (select
    case when p_mode='post-show' then ((a.day+a.ends) at time zone 'America/New_York')-interval '15 minutes'
      else ((a.day+a.starts) at time zone 'America/New_York')+interval '15 minutes' end as opens,
    ((a.day+a.ends) at time zone 'America/New_York')+interval '30 minutes' as closes
  ) x where w.id=p_week and a.day is not null and p_now<=x.closes;
$$;

create or replace function public.configure_dwts_automation(
  p_week_number integer,p_enabled boolean,
  p_modes text[] default array['get-weeks','pre-show']::text[],p_judge_order text[] default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w uuid;
begin
  if not coalesce(public.is_platform_admin(),false) and session_user<>'postgres' then raise exception 'Platform-owner access required'; end if;
  perform pg_advisory_xact_lock(2601005,1);
  if p_modes is null or not p_modes <@ array['get-weeks','pre-show','live-show','post-show','photos']::text[] then raise exception 'Unknown automation mode'; end if;
  select id into w from public.weeks where number=p_week_number;
  if w is null then raise exception 'Week not found'; end if;
  insert into public.dwts_automation_weeks(week_id,enabled,modes,judge_order,inherit_previous) values(w,p_enabled,p_modes,p_judge_order,false)
  on conflict(week_id) do update set enabled=excluded.enabled,modes=excluded.modes,judge_order=excluded.judge_order,inherit_previous=false,updated_at=now();
  update public.dwts_automation_jobs set next_run_at=now() where week_id=w;
  return jsonb_build_object('week',p_week_number,'enabled',p_enabled,'modes',p_modes);
end $$;

create or replace function public.heartbeat_dwts_worker(p_worker text,p_run uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if nullif(btrim(p_worker),'') is null or length(p_worker)>100 then raise exception 'Invalid worker name'; end if;
  perform pg_advisory_xact_lock(2601005,1);
  update public.dwts_automation_state set worker_name=p_worker,last_heartbeat_at=now() where id=1;
  if p_run is not null then
    update public.dwts_automation_jobs j set lease_until=now()+interval '40 minutes'
    from public.dwts_automation_runs r where j.active_run_id=p_run and r.id=p_run
      and r.worker_name=p_worker and r.status='running' and j.lease_until>now();
  end if;
  return jsonb_build_object('server_time',now());
end $$;

create or replace function public.claim_dwts_work(p_worker text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare j record; targets jsonb; opening timestamptz; order_names text[];
  expected text[]; run_id uuid; payload jsonb; next_due timestamptz;
begin
  perform public.heartbeat_dwts_worker(p_worker);
  -- Serialize database bookkeeping, not script execution: Wiki jobs remain independent
  -- of photo jobs and photo cooldowns. Only one photo job may run globally.
  perform pg_advisory_xact_lock(2601005,1);
  insert into public.dwts_automation_jobs(week_id,mode)
    select a.week_id,m from public.dwts_automation_weeks a cross join lateral unnest(a.modes) m
    where a.enabled on conflict(week_id,mode) do nothing;
  for j in select q.*,w.number,w.is_complete,w.is_finale,w.guest_judge_name,w.air_date,
    a.wiki_tag,a.judge_order from public.dwts_automation_jobs q
    join public.weeks w on w.id=q.week_id join public.dwts_automation_weeks a on a.week_id=w.id
    where a.enabled and q.mode=any(a.modes) and not w.is_complete
      and (w.number=1 or exists(select 1 from public.weeks p where p.number=w.number-1 and p.is_complete))
      and q.next_run_at<=now() and (q.lease_until is null or q.lease_until<=now())
    order by q.next_run_at,q.week_id,q.mode for update of q skip locked loop
    if j.active_run_id is not null then
      update public.dwts_automation_runs set status='expired',finished_at=now() where id=j.active_run_id and status='running';
    end if;
    if j.mode='get-weeks' and j.wiki_tag is not null then continue; end if;
    if j.mode<>'get-weeks' and j.mode<>'photos' and j.wiki_tag is null then continue; end if;
    if j.mode='post-show' and (j.is_finale or exists(select 1 from public.dances d where d.week_id=j.week_id and d.elimination_confirmed and d.elimination_result)) then continue; end if;
    targets:=public.dwts_pending_targets(j.week_id,j.mode);
    if j.mode<>'get-weeks' and jsonb_array_length(targets)=0 then continue; end if;
    -- Never guess which Wiki performance belongs to multiple dance rows.
    if exists(select 1 from jsonb_array_elements(targets) t group by t->>'partnership_id' having count(*)>1) then
      update public.dwts_automation_jobs set last_error='Multiple dances for a couple require explicit performance mapping',next_run_at=now()+interval '30 minutes' where id=j.id;
      continue;
    end if;
    if j.mode in ('photos','live-show','post-show') then
      opening:=public.dwts_window_opening(j.week_id,j.mode,now());
      if opening is null then continue; end if;
      if opening>now() then update public.dwts_automation_jobs set next_run_at=opening where id=j.id; continue; end if;
    end if;
    if j.mode='photos' then
      select photos_not_before into opening from public.dwts_automation_state where id=1;
      if opening>now() then update public.dwts_automation_jobs set next_run_at=opening where id=j.id; continue; end if;
      if exists(select 1 from public.dwts_automation_jobs where mode='photos' and lease_until>now()) then continue; end if;
    end if;
    order_names:=array['Carrie Ann','Derek','Bruno']::text[];
    if nullif(btrim(j.guest_judge_name),'') is not null then order_names:=order_names||array[btrim(j.guest_judge_name)]; end if;
    expected:=order_names;
    if j.judge_order is not null then order_names:=j.judge_order; end if;
    if j.mode='live-show' and ((j.guest_judge_name is not null and j.judge_order is null)
      or cardinality(order_names)<>cardinality(expected) or not order_names @> expected or not order_names <@ expected) then
      update public.dwts_automation_jobs set last_error='Set the explicit Wikipedia judge order for guest-judge score imports',next_run_at=now()+interval '5 minutes' where id=j.id;
      continue;
    end if;
    payload:=jsonb_build_object('mode',j.mode,'week_id',j.week_id,'week',j.number,
      'week_tag',j.wiki_tag,'targets',targets,'judge_order',order_names,
      'since',j.air_date,'folder','Images/Dances/Week '||j.number,
      'known_photo_posts',coalesce((select jsonb_agg(jsonb_build_object('post_id',r.post_id,
        'partnership_id',r.partnership_id,'files',r.files)) from public.dwts_photo_receipts r where r.week_id=j.week_id),'[]'::jsonb));
    insert into public.dwts_automation_runs(job_id,worker_name,payload) values(j.id,p_worker,payload) returning id into run_id;
    update public.dwts_automation_jobs set active_run_id=run_id,lease_until=now()+interval '40 minutes',last_error=null where id=j.id;
    return payload||jsonb_build_object('run_id',run_id,'lease_until',now()+interval '40 minutes');
  end loop;
  select min(q.next_run_at) into next_due from public.dwts_automation_jobs q
    join public.dwts_automation_weeks a on a.week_id=q.week_id join public.weeks w on w.id=q.week_id
    where a.enabled and not w.is_complete and q.mode=any(a.modes) and q.next_run_at>now();
  return jsonb_build_object('run_id',null,'poll_after_seconds',60,'next_run_at',next_due);
end $$;

-- Accept the scripts' raw Wiki JSON. Photo reports additionally need post_ids
-- and commit_sha on each uploaded_couples item (the updated worker supplies
-- these); a planned match/dry run can NEVER mark photos_uploaded true.
create or replace function public.report_dwts_work(p_worker text,p_run uuid,p_result jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.dwts_automation_runs%rowtype; j public.dwts_automation_jobs%rowtype;
  w public.weeks%rowtype; target jsonb; couple jsonb; perf jsonb; data jsonb;
  d public.dances%rowtype; n integer; checks integer;
  field_name text; value jsonb; score_item jsonb; score integer; total integer;
  names text[]; artist text; title text; dance_type text; v_song text;
  tag text; tagged jsonb; files jsonb; post jsonb; upload jsonb;
  cooldown integer:=0; errors jsonb:='[]'::jsonb; imported integer:=0;
  delay interval; old_marker text; is_failed boolean; has_candidate boolean:=false;
begin
  if p_result is null or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>2000000 then raise exception 'Invalid or oversized result'; end if;
  perform pg_advisory_xact_lock(2601005,1);
  select * into r from public.dwts_automation_runs where id=p_run;
  if not found or r.worker_name<>p_worker then raise exception 'Unknown run or worker'; end if;
  select * into j from public.dwts_automation_jobs where id=r.job_id for update;
  select * into r from public.dwts_automation_runs where id=p_run for update;
  if r.status in ('finished','failed') then return r.summary||jsonb_build_object('already_reported',true); end if;
  if r.status<>'running' or j.active_run_id is distinct from p_run or j.lease_until<=now() then raise exception 'Run lease expired; claim new work'; end if;
  select * into w from public.weeks where id=j.week_id for update;
  perform public.heartbeat_dwts_worker(p_worker);
  old_marker:=coalesce(current_setting('mirrorball.automation_import',true),'');
  perform set_config('mirrorball.automation_import','on',true);
  is_failed:=coalesce((p_result->>'failed_run')::boolean,false) or p_result ? 'error';
  if p_result ? 'error' then errors:=errors||jsonb_build_array(left(p_result->>'error',1000)); end if;
  if jsonb_typeof(p_result->'errors')='array' then
    errors:=errors||(p_result->'errors');
    for data in select * from jsonb_array_elements(p_result->'errors') loop
      if data->>'cooldown_seconds' ~ '^[0-9]{1,7}$' then cooldown:=greatest(cooldown,(data->>'cooldown_seconds')::integer); end if;
    end loop;
  end if;
  if w.is_complete then
    errors:=errors||jsonb_build_array('Week was completed while this job was running; ignored result');
  elsif j.mode='get-weeks' then
    select item into tagged from jsonb_array_elements(coalesce(p_result->'weeks','[]'::jsonb)) item
      where item->>'week'=w.number::text limit 1;
    tag:=nullif(btrim(tagged->>'week_tag'),'');
    if tag is not null and (tag not like '#Week\_'||w.number||':%' escape '\' or length(tag)>250) then tag:=null; end if;
    update public.dwts_automation_weeks a set
      wiki_tag_checks=case when tag is null then 0 when a.wiki_tag_candidate=tag then least(a.wiki_tag_checks+1,2) else 1 end,
      wiki_tag_candidate=tag,wiki_tag_last_check=p_run,updated_at=now()
      where week_id=w.id and a.wiki_tag_last_check is distinct from p_run returning wiki_tag_checks into checks;
    if checks=2 then
      update public.dwts_automation_weeks set wiki_tag=tag where week_id=w.id;
      update public.dwts_automation_jobs set next_run_at=now() where week_id=w.id and mode='pre-show';
    elsif checks=1 then has_candidate:=true; end if;
  elsif j.mode='photos' then
    if coalesce((p_result->>'dry_run')::boolean,false) then raise exception 'Dry-run uploads cannot be reported as production work'; end if;
    if p_result->>'week' is distinct from w.number::text then raise exception 'Photo result week mismatch'; end if;
    for upload in select * from jsonb_array_elements(coalesce(p_result->'uploaded_couples','[]'::jsonb)) loop
      begin
        select item into target from jsonb_array_elements(r.payload->'targets') item
          where item->>'star_name'=upload->>'star_name' and item->>'pro_name'=upload->>'pro_name';
        if target is null then raise exception 'Upload is not a claimed couple'; end if;
        files:=upload->'files';
        if jsonb_typeof(files) is distinct from 'array' or jsonb_array_length(files)=0
          or coalesce(upload->>'commit_sha','') !~ '^[0-9a-f]{40}$'
          or jsonb_typeof(upload->'post_ids') is distinct from 'array' or jsonb_array_length(upload->'post_ids')=0 then
          raise exception 'Upload receipt needs files, post IDs and a successful GitHub commit';
        end if;
        for data in select * from jsonb_array_elements(files) loop
          if left(coalesce(data->>'path',''),length(r.payload->>'folder')+1) <> (r.payload->>'folder')||'/'
            or data->>'path' ~ '(^|/)\.\.(/|$)' or data->>'path' ~ '[\\]' then raise exception 'Invalid upload path'; end if;
          if position((target->>'star_name')||' and '||(target->>'pro_name')||'-' in data->>'path')=0 then raise exception 'Upload filename does not match the couple'; end if;
        end loop;
        select * into d from public.dances where id=(target->>'dance_id')::uuid and week_id=w.id
          and partnership_id=(target->>'partnership_id')::uuid and kind='competitive' for update;
        if not found then raise exception 'Claimed dance no longer exists'; end if;
        for post in select * from jsonb_array_elements(upload->'post_ids') loop
          if jsonb_typeof(post)<>'string' or (post#>>'{}') !~ '^[0-9]{1,30}$' then raise exception 'Invalid source post ID'; end if;
          if exists(select 1 from public.dwts_photo_receipts where week_id=w.id and post_id=post#>>'{}' and partnership_id<>d.partnership_id) then raise exception 'Source post already belongs to another couple'; end if;
          insert into public.dwts_photo_receipts(week_id,post_id,partnership_id,files,commit_sha)
          values(w.id,post#>>'{}',d.partnership_id,files,upload->>'commit_sha') on conflict(week_id,post_id) do nothing;
        end loop;
        update public.dances set photos_uploaded=true where id=d.id;
        imported:=imported+1;
      exception when others then errors:=errors||jsonb_build_array(left(sqlerrm,1000)); end;
    end loop;
    if is_failed then
      cooldown:=greatest(cooldown,case when coalesce((p_result->>'skip_next_run')::boolean,false) then 600 else 300 end);
      update public.dwts_automation_state set photos_not_before=greatest(coalesce(photos_not_before,now()),now()+make_interval(secs=>cooldown)) where id=1;
    end if;
  else
    if p_result ? 'week' and p_result->>'week' is distinct from w.number::text then raise exception 'Wiki result week mismatch'; end if;
    if not is_failed and (p_result->>'mode' is distinct from j.mode or p_result->>'week_tag' is distinct from r.payload->>'week_tag') then raise exception 'Wiki result mode/tag mismatch'; end if;
    for target in select * from jsonb_array_elements(r.payload->'targets') loop
      select * into d from public.dances where id=(target->>'dance_id')::uuid and week_id=w.id
        and partnership_id=(target->>'partnership_id')::uuid and kind='competitive' for update;
      if not found then continue; end if;
      couple:=null; perf:=null;
      select item into couple from jsonb_array_elements(coalesce(p_result->'couples','[]'::jsonb)) item
        where item->>'star_name'=target->>'star_name' and item->>'pro_name'=target->>'pro_name';
      if not is_failed and coalesce((couple->>'found')::boolean,false)
        and jsonb_typeof(couple->'performances')='array' and jsonb_array_length(couple->'performances')=1 then perf:=couple->'performances'->0; end if;
      if jsonb_typeof(couple->'performances')='array' and jsonb_array_length(couple->'performances')>1 then
        errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'error','Multiple Wikipedia performances need explicit mapping; not guessing'));
      end if;
      if j.mode='pre-show' then
        foreach field_name in array array['dance_type','song'] loop
          if field_name='dance_type' and d.dance_type_confirmed or field_name='song' and d.song_confirmed then continue; end if;
          begin
            value:=null;
            if field_name='dance_type' then
              dance_type:=public.canonical_dance_type(nullif(btrim(perf->>'dance'),''));
              if dance_type is not null then value:=to_jsonb(dance_type); end if;
            else
              title:=nullif(btrim(perf->>'song'),''); artist:=nullif(btrim(perf->>'artist'),'');
              if title is not null then value:=jsonb_build_object('title',title,'artist',artist); end if;
            end if;
            n:=public.dwts_observe_field(d.id,field_name,value,p_run);
            if n=1 then has_candidate:=true; end if;
            if field_name='dance_type' then
              update public.dances set dance_type=case when value is null then null else value#>>'{}' end,dance_type_confirmed=n=2 where id=d.id;
            else
              v_song:=case when value is null then null else title||case when artist is null then '' else ' by '||artist end end;
              update public.dances set song=v_song,song_confirmed=n=2 where id=d.id;
            end if;
            if n=2 then imported:=imported+1; end if;
          exception when others then
            perform public.dwts_observe_field(d.id,field_name,null,p_run);
            errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'field',field_name,'error',left(sqlerrm,1000)));
          end;
        end loop;
      elsif j.mode='live-show' and not d.scores_confirmed then
        begin
          names:=array(select jsonb_array_elements_text(r.payload->'judge_order'));
          if public.dance_expected_judges(d.id) is null
            or not names @> public.dance_expected_judges(d.id) or not names <@ public.dance_expected_judges(d.id)
            or cardinality(names)<>cardinality(public.dance_expected_judges(d.id)) then raise exception 'Judge panel changed during run'; end if;
          value:=null; total:=0;
          if jsonb_typeof(perf->'scores')='array' and jsonb_array_length(perf->'scores')=cardinality(names) then
            value:='[]'::jsonb; checks:=1;
            for score_item in select * from jsonb_array_elements(perf->'scores') loop
              if jsonb_typeof(score_item)<>'number' or (score_item#>>'{}') !~ '^(10|[1-9])$' then raise exception 'Each judge score must be an integer 1–10'; end if;
              score:=(score_item#>>'{}')::integer; total:=total+score;
              value:=value||jsonb_build_array(jsonb_build_object('judge_name',names[checks],'score',score)); checks:=checks+1;
            end loop;
            if perf->>'total' is null or perf->>'total' !~ '^[0-9]{1,2}$' or (perf->>'total')::integer<>total then raise exception 'Score total does not match individual judges'; end if;
          end if;
          if value is not null and exists(select 1 from public.dance_judge_scores s
            join jsonb_array_elements(value) v on v->>'judge_name'=s.judge_name
            where s.dance_id=d.id and s.confirmed and s.score<>(v->>'score')::integer) then raise exception 'Wikipedia conflicts with a manually confirmed judge score'; end if;
          n:=public.dwts_observe_field(d.id,'scores',value,p_run);
          if value is null then
            delete from public.dance_judge_scores where dance_id=d.id and not confirmed;
          else
            for score_item in select * from jsonb_array_elements(value) loop
              insert into public.dance_judge_scores(dance_id,judge_name,score,confirmed)
              values(d.id,score_item->>'judge_name',(score_item->>'score')::integer,n=2)
              on conflict(dance_id,judge_name) do update set score=excluded.score,confirmed=excluded.confirmed
                where not public.dance_judge_scores.confirmed;
            end loop;
          end if;
          perform public.refresh_dance_scores_confirmed(d.id);
          if n=2 then imported:=imported+1; end if;
        exception when others then
          perform public.dwts_observe_field(d.id,'scores',null,p_run);
          delete from public.dance_judge_scores where dance_id=d.id and not confirmed;
          perform public.refresh_dance_scores_confirmed(d.id);
          errors:=errors||jsonb_build_array(jsonb_build_object('dance_id',d.id,'field','scores','error',left(sqlerrm,1000)));
        end;
      elsif j.mode='post-show' and not d.elimination_confirmed then
        value:=case when jsonb_typeof(perf->'eliminated')='boolean' then perf->'eliminated' end;
        n:=public.dwts_observe_field(d.id,'elimination',value,p_run);
        update public.dances set elimination_result=case when value is null then null else (value#>>'{}')::boolean end,
          elimination_confirmed=n=2 where id=d.id;
        if n=2 then imported:=imported+1; end if;
      end if;
    end loop;
  end if;
  delay:=case when j.mode in ('photos','live-show','post-show') then interval '5 minutes'
    when has_candidate then interval '1 minute' when j.mode='get-weeks' then interval '1 hour' else interval '30 minutes' end;
  update public.dwts_automation_jobs set active_run_id=null,lease_until=null,
    next_run_at=greatest(now()+delay,case when j.mode='photos' then (select photos_not_before from public.dwts_automation_state where id=1) else now() end),
    last_error=case when jsonb_array_length(errors)>0 then left(errors::text,2000) end where id=j.id;
  data:=jsonb_build_object('run_id',p_run,'mode',j.mode,'confirmed_or_uploaded',imported,
    'errors',errors,'next_run_at',(select next_run_at from public.dwts_automation_jobs where id=j.id));
  update public.dwts_automation_runs set status=case when is_failed or jsonb_array_length(errors)>0 then 'failed' else 'finished' end,
    finished_at=now(),summary=data where id=p_run;
  perform set_config('mirrorball.automation_import',old_marker,true);
  return data;
end $$;

-- On manual completion, all this week's competitive photos are done; do not
-- schedule retroactive downloads. Performance photos remain entirely manual.
create or replace function public.finish_dwts_week_photos()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.is_complete and not old.is_complete then
    update public.dances set photos_uploaded=true where week_id=new.id and kind='competitive';
    -- Once enabled, continue into the next week after manual completion.
    -- An explicitly configured/paused next week is never re-enabled here.
    insert into public.dwts_automation_weeks(week_id,enabled,modes)
      select w.id,a.enabled,a.modes from public.weeks w
      join public.dwts_automation_weeks a on a.week_id=new.id
      where w.number=new.number+1
    on conflict(week_id) do update set enabled=excluded.enabled,modes=excluded.modes,updated_at=now()
      where public.dwts_automation_weeks.inherit_previous;
  end if;
  return null;
end $$;
drop trigger if exists finish_dwts_week_photos on public.weeks;
create trigger finish_dwts_week_photos after update of is_complete on public.weeks
  for each row execute function public.finish_dwts_week_photos();

create or replace function public.seed_dwts_automation_week()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.dwts_automation_weeks(week_id,enabled,modes)
    select new.id,coalesce(a.enabled,false),coalesce(a.modes,array['get-weeks','pre-show']::text[])
    from (select 1) seed left join public.weeks w on w.number=new.number-1 and w.is_complete
      left join public.dwts_automation_weeks a on a.week_id=w.id
  on conflict(week_id) do nothing;
  return null;
end $$;
drop trigger if exists seed_dwts_automation_week on public.weeks;
create trigger seed_dwts_automation_week after insert on public.weeks
  for each row execute function public.seed_dwts_automation_week();

revoke all on function public.dwts_observe_field(uuid,text,jsonb,uuid),public.dwts_pending_targets(uuid,text),
  public.dwts_window_opening(uuid,text,timestamptz),public.finish_dwts_week_photos(),public.seed_dwts_automation_week(),
  public.configure_dwts_automation(integer,boolean,text[],text[]),public.heartbeat_dwts_worker(text,uuid),
  public.claim_dwts_work(text),public.report_dwts_work(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.configure_dwts_automation(integer,boolean,text[],text[]) to authenticated;
grant execute on function public.heartbeat_dwts_worker(text,uuid),public.claim_dwts_work(text),
  public.report_dwts_work(text,uuid,jsonb) to service_role;

notify pgrst, 'reload schema';
commit;

-- Send this single row back. No enabled weeks should appear on first install.
select (select count(*) from public.dwts_automation_weeks where enabled) as enabled_weeks,
  count(*) filter(where w.is_complete) as previous_competitive_dances,
  count(*) filter(where w.is_complete and d.photos_uploaded) as previous_photos_marked_done,
  count(*) filter(where not w.is_complete and not d.photos_uploaded) as upcoming_couples_needing_photos
from public.dances d join public.weeks w on w.id=d.week_id where d.kind='competitive';
