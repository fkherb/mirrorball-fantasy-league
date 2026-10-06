-- STEP 3: read-only previews, GitHub reconciliation and restart recovery.
-- Run after add-dwts-automation-functions.sql. Enables no automation.
begin;

create or replace function public.preview_dwts_work(p_week_number integer,p_mode text,p_week_tag text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w public.weeks%rowtype; a public.dwts_automation_weeks%rowtype;
  tag text; judges text[];
begin
  if p_mode not in ('get-weeks','pre-show','live-show','post-show','photos') then raise exception 'Unknown mode'; end if;
  select * into w from public.weeks where number=p_week_number;
  if not found then raise exception 'Week not found'; end if;
  select * into a from public.dwts_automation_weeks where week_id=w.id;
  tag:=coalesce(nullif(btrim(p_week_tag),''),a.wiki_tag);
  if p_mode not in ('get-weeks','photos') and tag is null then raise exception 'Supply a week tag for this read-only preview'; end if;
  judges:=array['Carrie Ann','Derek','Bruno']::text[];
  if nullif(btrim(w.guest_judge_name),'') is not null then judges:=judges||array[btrim(w.guest_judge_name)]; end if;
  if p_mode='live-show' and w.guest_judge_name is not null and a.judge_order is null then raise exception 'Configure the guest judge order before importing scores'; end if;
  return jsonb_build_object('mode',p_mode,'week',w.number,'week_id',w.id,'week_tag',tag,
    'targets',public.dwts_pending_targets(w.id,p_mode),'judge_order',coalesce(a.judge_order,judges),
    'since',w.air_date,'folder','Images/Dances/Week '||w.number,'known_photo_posts','[]'::jsonb);
end $$;

-- The worker reads GitHub BEFORE X. Existing manually uploaded files, or an
-- upload whose report was interrupted, count as done without downloading again.
-- This stores no fabricated X post IDs. Genuine new uploads still use receipts.
create or replace function public.reconcile_dwts_photos(p_worker text,p_run uuid,p_verified jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.dwts_automation_runs%rowtype; j public.dwts_automation_jobs%rowtype;
  item jsonb; target jsonb; f jsonb; verified jsonb:='[]'::jsonb; folder text;
begin
  perform pg_advisory_xact_lock(2601005,1);
  select * into r from public.dwts_automation_runs where id=p_run;
  if not found or r.worker_name<>p_worker then raise exception 'Unknown run or worker'; end if;
  select * into j from public.dwts_automation_jobs where id=r.job_id for update;
  if r.status<>'running' or j.active_run_id is distinct from p_run or j.lease_until<=now() then raise exception 'Run lease expired'; end if;
  if j.mode<>'photos' or jsonb_typeof(p_verified) is distinct from 'array' then raise exception 'Expected photo reconciliation'; end if;
  folder:=r.payload->>'folder';
  for item in select * from jsonb_array_elements(p_verified) loop
    select t into target from jsonb_array_elements(r.payload->'targets') t where t->>'dance_id'=item->>'dance_id';
    if target is null or coalesce(item->>'commit_sha','') !~ '^[0-9a-f]{40}$'
      or jsonb_typeof(item->'files') is distinct from 'array' or jsonb_array_length(item->'files')=0 then raise exception 'Invalid verified photo receipt'; end if;
    for f in select * from jsonb_array_elements(item->'files') loop
      if not starts_with(coalesce(f->>'path',''),folder||'/'||(target->>'star_name')||' and '||(target->>'pro_name')||'-')
        or f->>'path' ~ '(^|/)\.\.(/|$)' or f->>'path' ~ '[\\]'
        or f->>'path' !~* '\.(avif|jpg|jpeg|png|webp)$' then raise exception 'Photo does not match the claimed couple'; end if;
    end loop;
    update public.dances set photos_uploaded=true where id=(target->>'dance_id')::uuid
      and week_id=j.week_id and partnership_id=(target->>'partnership_id')::uuid and kind='competitive';
    if found then verified:=verified||jsonb_build_array(target->>'dance_id'); end if;
  end loop;
  return jsonb_build_object('verified_dance_ids',verified);
end $$;

-- If the SAME run has not been reclaimed, renewing after a server restart is
-- safe. Once a replacement run exists, the old worker cannot renew its lease.
create or replace function public.heartbeat_dwts_worker(p_worker text,p_run uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if nullif(btrim(p_worker),'') is null or length(p_worker)>100 then raise exception 'Invalid worker name'; end if;
  perform pg_advisory_xact_lock(2601005,1);
  update public.dwts_automation_state set worker_name=p_worker,last_heartbeat_at=now() where id=1;
  if p_run is not null then
    update public.dwts_automation_jobs j set lease_until=now()+interval '40 minutes'
    from public.dwts_automation_runs r where j.active_run_id=p_run and r.id=p_run
      and r.worker_name=p_worker and r.status='running';
    if not found then raise exception 'Run lease expired or replaced'; end if;
  end if;
  return jsonb_build_object('server_time',now());
end $$;

revoke all on function public.preview_dwts_work(integer,text,text),public.reconcile_dwts_photos(text,uuid,jsonb)
  from public,anon,authenticated;
grant execute on function public.preview_dwts_work(integer,text,text),public.reconcile_dwts_photos(text,uuid,jsonb)
  to service_role;
notify pgrst,'reload schema';
commit;
select (select count(*) from public.dwts_automation_weeks where enabled) as enabled_weeks,
  to_regprocedure('public.preview_dwts_work(integer,text,text)') is not null as preview_ready,
  to_regprocedure('public.reconcile_dwts_photos(text,uuid,jsonb)') is not null as photo_reconciliation_ready;
