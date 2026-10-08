-- Run AFTER draft-start-and-frozen-cast.sql and
-- lock-rosters-from-airing-until-week-complete.sql. Safe to rerun.
-- Regular leagues only. No roster, score, snapshot, timer, or invite is reset.
begin;

alter table public.leagues add column if not exists draft_roster_limits jsonb not null default '{}'::jsonb;

-- Preserve the numeric allowances of drafts already running on the old rules.
-- New drafts capture the new rounded-up limits below instead.
update public.leagues l set draft_roster_limits = jsonb_build_object(
  'pro_max', public.league_category_limit(l.id,'Pro') + public.league_flex_allowance(l.id),
  'star_max', public.league_category_limit(l.id,'Star') + public.league_flex_allowance(l.id),
  'active_max', public.league_category_limit(l.id,'Pro') + public.league_category_limit(l.id,'Star') + public.league_flex_allowance(l.id),
  'bonus_max', public.league_bonus_draft_limit(l.id), 'roster_size', l.roster_size,
  'team_count', (select count(*) from public.fantasy_teams t where t.league_id=l.id),
  'exempt', false, 'legacy_draft_limits', true)
where l.status='drafting' and l.id<>public.default_fantasy_league_id() and l.draft_roster_limits='{}'::jsonb;

create or replace function public.league_roster_team_ids(p_league_id uuid)
returns uuid[] language sql stable security definer set search_path='' as $$
  select coalesce(array_agg(t.id order by t.id),'{}'::uuid[])
  from public.fantasy_teams t join public.leagues l on l.id=t.league_id
  where l.id=p_league_id and (exists (
    select 1 from public.league_members m where m.league_id=l.id
    and m.fantasy_team_id=t.id and m.status='active') or (l.status<>'setup' and (
      exists(select 1 from public.league_roster_assignments a where a.league_id=l.id and a.fantasy_team_id=t.id)
      or exists(select 1 from public.league_draft_order d where d.league_id=l.id and d.fantasy_team_id=t.id))));
$$;

create or replace function public.league_roster_limits(p_league_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_league public.leagues; v_teams integer; v_active integer; v_max integer; v_role integer;
begin
  select * into v_league from public.leagues where id=p_league_id;
  if v_league.id is null then raise exception 'League not found.'; end if;
  if v_league.status='drafting' and v_league.draft_roster_limits<>'{}'::jsonb then
    return v_league.draft_roster_limits;
  end if;
  v_teams := greatest(1,cardinality(public.league_roster_team_ids(p_league_id)));
  select count(*) into v_active from public.cast_members c
    where public.league_draft_role(p_league_id,c.id) in ('Pro','Star');
  v_max := ceil(v_active::numeric/v_teams)::integer;
  v_role := ceil(v_active::numeric/v_teams/2)::integer;
  return jsonb_build_object('pro_max',v_role,'star_max',v_role,'active_max',v_max,
    'bonus_max',greatest(0,v_league.roster_size-v_max+1),'roster_size',v_league.roster_size,
    'team_count',v_teams,'exempt',p_league_id=public.default_fantasy_league_id(),
    'legacy_draft_limits',false);
end;
$$;

create or replace function public.capture_league_draft_cast_roles()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status='setup' and new.status='drafting' and new.id<>public.default_fantasy_league_id() then
    new.draft_cast_roles := (select coalesce(jsonb_object_agg(c.id::text,c.role),'{}'::jsonb) from public.cast_members c);
    new.draft_roster_limits := public.league_roster_limits(new.id);
  end if;
  return new;
end;
$$;

create or replace function public.league_category_limit(p_league_id uuid,p_role text)
returns integer language sql stable security definer set search_path='' as $$
  select case p_role when 'Pro' then (public.league_roster_limits(p_league_id)->>'pro_max')::integer
    when 'Star' then (public.league_roster_limits(p_league_id)->>'star_max')::integer else null end;
$$;
-- Compatibility helper only: Flex is no longer a separate allowance.
create or replace function public.league_flex_allowance(p_league_id uuid)
returns integer language sql stable security definer set search_path='' as $$ select 0; $$;
create or replace function public.league_bonus_draft_limit(p_league_id uuid)
returns integer language sql stable security definer set search_path='' as $$
  select (public.league_roster_limits(p_league_id)->>'bonus_max')::integer;
$$;

create or replace function public.league_roster_counts(p_league_id uuid,p_team_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('Pro',count(*) filter(where public.league_draft_role(p_league_id,a.cast_member_id)='Pro'),
    'Star',count(*) filter(where public.league_draft_role(p_league_id,a.cast_member_id)='Star'),
    'Bonus',count(*) filter(where public.league_draft_role(p_league_id,a.cast_member_id) not in ('Pro','Star')))
  from public.league_roster_assignments a where a.league_id=p_league_id and a.fantasy_team_id=p_team_id;
$$;

-- One pure validator shared by offers, counters, acceptance, swaps, and the UI
-- RPC. Existing excesses may remain, but the outgoing category must be overfull
-- and the incoming category must have room. Partial corrections are allowed.
create or replace function public.roster_exchange_issue(p_counts jsonb,p_limits jsonb,p_outgoing text,p_incoming text)
returns text language plpgsql immutable set search_path='' as $$
declare v_caps jsonb; v_after jsonb; v_over text[] := '{}'; v_role text; v_active integer; v_combined boolean;
begin
  if (p_limits->>'exempt')::boolean then return null; end if;
  if p_outgoing not in ('Pro','Star','Bonus') or p_incoming not in ('Pro','Star','Bonus')
    or coalesce((p_counts->>p_outgoing)::integer,0)<1 then return 'Choose a cast member on your roster.'; end if;
  v_caps := jsonb_build_object('Pro',p_limits->'pro_max','Star',p_limits->'star_max','Bonus',p_limits->'bonus_max');
  foreach v_role in array array['Pro','Star','Bonus'] loop
    if (p_counts->>v_role)::integer>(v_caps->>v_role)::integer then v_over:=array_append(v_over,v_role); end if;
  end loop;
  v_active := (p_counts->>'Pro')::integer+(p_counts->>'Star')::integer;
  v_combined := v_active>(p_limits->>'active_max')::integer;
  if cardinality(v_over)>0 or v_combined then
    if (cardinality(v_over)>0 and not(p_outgoing=any(v_over)))
      or (cardinality(v_over)=0 and p_outgoing='Bonus') then
      return 'Release or offer cast only from an over-limit category.';
    end if;
    if p_incoming=p_outgoing or p_incoming=any(v_over) then
      return 'Choose an incoming category with room; this exchange must reduce an excess.';
    end if;
    if v_combined and p_incoming<>'Bonus' then
      return 'Too many Pros and Stars combined: exchange an active member for Bonus cast.';
    end if;
  end if;
  v_after := jsonb_set(p_counts,array[p_outgoing],to_jsonb((p_counts->>p_outgoing)::integer-1));
  v_after := jsonb_set(v_after,array[p_incoming],to_jsonb((v_after->>p_incoming)::integer+1));
  foreach v_role in array array['Pro','Star','Bonus'] loop
    if (v_after->>v_role)::integer>greatest((v_caps->>v_role)::integer,(p_counts->>v_role)::integer) then
      return format('This exchange would exceed the %s limit of %s.',v_role,v_caps->>v_role);
    end if;
  end loop;
  if (v_after->>'Pro')::integer+(v_after->>'Star')::integer>greatest(v_active,(p_limits->>'active_max')::integer) then
    return format('This exchange would exceed the combined Pro/Star limit of %s.',p_limits->>'active_max');
  end if;
  return null;
end;
$$;

-- Exact integral max-flow feasibility, not merely a per-role quota reserve.
-- Role -> team-active -> team edges enforce both individual and shared caps.
create or replace function public.league_draft_can_finish(p_league_id uuid,p_team_id uuid default null,p_category text default null)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare v_limits jsonb:=public.league_roster_limits(p_league_id); v_ids uuid[]:=public.league_roster_team_ids(p_league_id);
  v_n integer:=cardinality(v_ids); v_sink integer:=5+2*v_n; v_edges integer[][];
  v_pool jsonb; v_counts jsonb; v_role text; v_i integer; v_a integer; v_t integer;
  v_remaining integer; v_demand integer:=0; v_flow integer:=0; v_parent integer[];
  v_queue integer[]; v_q integer; v_from integer; v_to integer; v_amount integer;
begin
  if p_league_id=public.default_fantasy_league_id() then return true; end if;
  if v_n not between 3 and 5 then return false; end if;
  if p_team_id is not null and (not(p_team_id=any(v_ids)) or p_category not in ('Pro','Star','Bonus')) then return false; end if;
  select jsonb_build_object('Pro',count(*) filter(where public.league_draft_role(p_league_id,c.id)='Pro'),
    'Star',count(*) filter(where public.league_draft_role(p_league_id,c.id)='Star'),
    'Bonus',count(*) filter(where public.league_draft_role(p_league_id,c.id) not in ('Pro','Star')))
    into v_pool from public.cast_members c where not exists(select 1 from public.league_roster_assignments a
      where a.league_id=p_league_id and a.cast_member_id=c.id);
  if p_team_id is not null then
    if (v_pool->>p_category)::integer<1 then return false; end if;
    v_pool:=jsonb_set(v_pool,array[p_category],to_jsonb((v_pool->>p_category)::integer-1));
  end if;
  v_edges:=array_fill(0,array[v_sink,v_sink]);
  v_edges[1][2]:=(v_pool->>'Pro')::integer;
  v_edges[1][3]:=(v_pool->>'Star')::integer;
  v_edges[1][4]:=(v_pool->>'Bonus')::integer;
  for v_i in 1..v_n loop
    v_counts:=public.league_roster_counts(p_league_id,v_ids[v_i]);
    if v_ids[v_i]=p_team_id then v_counts:=jsonb_set(v_counts,array[p_category],to_jsonb((v_counts->>p_category)::integer+1)); end if;
    v_remaining:=(v_limits->>'roster_size')::integer-(v_counts->>'Pro')::integer-(v_counts->>'Star')::integer-(v_counts->>'Bonus')::integer;
    if v_remaining<0 or (v_counts->>'Pro')::integer>(v_limits->>'pro_max')::integer
      or (v_counts->>'Star')::integer>(v_limits->>'star_max')::integer
      or (v_counts->>'Bonus')::integer>(v_limits->>'bonus_max')::integer
      or (v_counts->>'Pro')::integer+(v_counts->>'Star')::integer>(v_limits->>'active_max')::integer then return false; end if;
    v_a:=5+2*(v_i-1); v_t:=v_a+1;
    v_edges[2][v_a]:=(v_limits->>'pro_max')::integer-(v_counts->>'Pro')::integer;
    v_edges[3][v_a]:=(v_limits->>'star_max')::integer-(v_counts->>'Star')::integer;
    v_edges[4][v_t]:=(v_limits->>'bonus_max')::integer-(v_counts->>'Bonus')::integer;
    v_edges[v_a][v_t]:=(v_limits->>'active_max')::integer-(v_counts->>'Pro')::integer-(v_counts->>'Star')::integer;
    v_edges[v_t][v_sink]:=v_remaining; v_demand:=v_demand+v_remaining;
  end loop;
  while v_flow<v_demand loop
    v_parent:=array_fill(0,array[v_sink]); v_parent[1]:=1; v_queue:=array[1]; v_q:=1;
    while v_q<=cardinality(v_queue) and v_parent[v_sink]=0 loop
      v_from:=v_queue[v_q]; v_q:=v_q+1;
      for v_to in 1..v_sink loop
        if v_parent[v_to]=0 and v_edges[v_from][v_to]>0 then
          v_parent[v_to]:=v_from; v_queue:=array_append(v_queue,v_to);
        end if;
      end loop;
    end loop;
    if v_parent[v_sink]=0 then return false; end if;
    v_amount:=v_demand-v_flow; v_to:=v_sink;
    while v_to<>1 loop v_from:=v_parent[v_to]; v_amount:=least(v_amount,v_edges[v_from][v_to]); v_to:=v_from; end loop;
    v_to:=v_sink;
    while v_to<>1 loop
      v_from:=v_parent[v_to]; v_edges[v_from][v_to]:=v_edges[v_from][v_to]-v_amount;
      v_edges[v_to][v_from]:=v_edges[v_to][v_from]+v_amount; v_to:=v_from;
    end loop;
    v_flow:=v_flow+v_amount;
  end loop;
  return true;
end;
$$;

create or replace function public.league_pick_is_eligible(p_league_id uuid,p_team_id uuid,p_cast_member_id uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare v_role text;
begin
  v_role:=public.league_draft_role(p_league_id,p_cast_member_id);
  if v_role is null or exists(select 1 from public.league_roster_assignments where league_id=p_league_id and cast_member_id=p_cast_member_id) then return false; end if;
  return public.league_draft_can_finish(p_league_id,p_team_id,public.league_cast_category(v_role));
end;
$$;

create or replace function public.check_balanced_draft_capacity()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.id<>public.default_fantasy_league_id() and new.status='drafting' and old.status<>'drafting'
    and not public.league_draft_can_finish(new.id) then
    raise exception 'This draft cannot fill every team under the current Pro, Star, combined active, and Bonus limits.';
  end if;
  return new;
end;
$$;

create or replace function public.choose_ordered_random_draft_cast(p_league_id uuid,p_team_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare v_category text; v_candidate uuid;
begin
  -- One eligibility calculation per category, not one max-flow per portrait.
  foreach v_category in array array['Pro','Star','Bonus'] loop
    select c.id into v_candidate from public.cast_members c
      where public.league_cast_category(public.league_draft_role(p_league_id,c.id))=v_category
      and public.league_draft_role(p_league_id,c.id) is not null
      and not exists(select 1 from public.league_roster_assignments a where a.league_id=p_league_id and a.cast_member_id=c.id)
      order by random() limit 1;
    if v_candidate is not null and public.league_pick_is_eligible(p_league_id,p_team_id,v_candidate) then return v_candidate; end if;
  end loop;
  return null;
end;
$$;

drop trigger if exists enforce_league_draft_role_reserves on public.league_roster_assignments;
drop trigger if exists enforce_secondary_league_category_limit on public.league_roster_assignments;
create or replace function public.guard_dynamic_roster_insert()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_status text;
begin
  if new.league_id=public.default_fantasy_league_id() then return new; end if;
  select status into v_status from public.leagues where id=new.league_id for update;
  if v_status='active' then raise exception 'Active roster changes must be one-for-one swaps or trades.'; end if;
  if v_status='drafting' and not public.league_pick_is_eligible(new.league_id,new.fantasy_team_id,new.cast_member_id) then
    raise exception 'That pick exceeds a limit or is needed for another team to finish drafting.';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_dynamic_roster_insert on public.league_roster_assignments;
create trigger guard_dynamic_roster_insert before insert on public.league_roster_assignments
  for each row execute function public.guard_dynamic_roster_insert();

-- Validate a completed UPDATE statement, not a temporary intermediate trade
-- row. Acceptance and orphan-team auto-accept both use the existing atomic
-- two-row UPDATE, so they receive the same validation without RPC rewrites.
create or replace function public.guard_dynamic_roster_update()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_team record; v_out uuid[]; v_in uuid[]; v_out_role text; v_in_role text;
  v_counts jsonb; v_issue text; v_limits jsonb;
begin
  for v_team in select distinct league_id,fantasy_team_id from (
    select league_id,fantasy_team_id from old_rosters union select league_id,fantasy_team_id from new_rosters) t
  loop
    if v_team.league_id=public.default_fantasy_league_id()
      or (select status from public.leagues where id=v_team.league_id)<>'active' then continue; end if;
    select array_agg(cast_member_id) into v_out from (
      select cast_member_id from old_rosters where league_id=v_team.league_id and fantasy_team_id=v_team.fantasy_team_id
      except select cast_member_id from new_rosters where league_id=v_team.league_id and fantasy_team_id=v_team.fantasy_team_id) t;
    select array_agg(cast_member_id) into v_in from (
      select cast_member_id from new_rosters where league_id=v_team.league_id and fantasy_team_id=v_team.fantasy_team_id
      except select cast_member_id from old_rosters where league_id=v_team.league_id and fantasy_team_id=v_team.fantasy_team_id) t;
    if coalesce(cardinality(v_out),0)=0 and coalesce(cardinality(v_in),0)=0 then continue; end if;
    if coalesce(cardinality(v_out),0)<>1 or coalesce(cardinality(v_in),0)<>1 then raise exception 'Roster exchanges must be one-for-one.'; end if;
    v_out_role:=public.league_cast_category(public.league_draft_role(v_team.league_id,v_out[1]));
    v_in_role:=public.league_cast_category(public.league_draft_role(v_team.league_id,v_in[1]));
    v_counts:=public.league_roster_counts(v_team.league_id,v_team.fantasy_team_id);
    v_counts:=jsonb_set(v_counts,array[v_in_role],to_jsonb((v_counts->>v_in_role)::integer-1));
    v_counts:=jsonb_set(v_counts,array[v_out_role],to_jsonb((v_counts->>v_out_role)::integer+1));
    v_limits:=public.league_roster_limits(v_team.league_id);
    v_issue:=public.roster_exchange_issue(v_counts,v_limits,v_out_role,v_in_role);
    if v_issue is not null then raise exception '%',v_issue; end if;
  end loop;
  return null;
end;
$$;
drop trigger if exists guard_dynamic_roster_update on public.league_roster_assignments;
create trigger guard_dynamic_roster_update after update on public.league_roster_assignments
  referencing old table as old_rosters new table as new_rosters
  for each statement execute function public.guard_dynamic_roster_update();

create or replace function public.check_secondary_league_trade_role_limits()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_side integer; v_team uuid; v_out uuid; v_in uuid; v_issue text;
begin
  if new.league_id=public.default_fantasy_league_id() then return new; end if;
  for v_side in 1..2 loop
    v_team:=case when v_side=1 then new.initiator_team_id else new.counterparty_team_id end;
    v_out:=case when v_side=1 then new.initiator_cast_member_id else new.counterparty_cast_member_id end;
    v_in:=case when v_side=1 then new.counterparty_cast_member_id else new.initiator_cast_member_id end;
    v_issue:=public.roster_exchange_issue(public.league_roster_counts(new.league_id,v_team),public.league_roster_limits(new.league_id),
      public.league_cast_category(public.league_draft_role(new.league_id,v_out)),public.league_cast_category(public.league_draft_role(new.league_id,v_in)));
    if v_issue is not null then raise exception '%',v_issue; end if;
  end loop;
  return new;
end;
$$;

-- Preserve the existing authorization/default-league/draft/clock path. Only
-- regular active swaps change: replace the outgoing row atomically so the
-- statement validator sees both sides and can allow partial corrections.
do $$ begin
  if to_regprocedure('public.claim_league_cast_member_before_dynamic_rosters(uuid,uuid,uuid)') is null then
    alter function public.claim_league_cast_member(uuid,uuid,uuid) rename to claim_league_cast_member_before_dynamic_rosters;
  end if;
end $$;
revoke all on function public.claim_league_cast_member_before_dynamic_rosters(uuid,uuid,uuid) from public,anon,authenticated;
create or replace function public.claim_league_cast_member(p_league_id uuid,p_incoming_cast_member_id uuid,p_outgoing_cast_member_id uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare v_status text; v_team uuid;
begin
  if auth.uid() is null then raise exception 'Sign in to claim cast.'; end if;
  select status into v_status from public.leagues where id=p_league_id for update;
  if p_league_id=public.default_fantasy_league_id() or v_status is distinct from 'active' then
    perform public.claim_league_cast_member_before_dynamic_rosters(p_league_id,p_incoming_cast_member_id,p_outgoing_cast_member_id); return;
  end if;
  select fantasy_team_id into v_team from public.league_members where league_id=p_league_id and user_id=auth.uid() and status='active';
  if v_team is null then raise exception 'League membership required.'; end if;
  if public.league_trade_airing_locked() then raise exception 'Roster changes are paused from airtime until this week is marked complete.'; end if;
  if p_outgoing_cast_member_id is null or p_outgoing_cast_member_id=p_incoming_cast_member_id then raise exception 'Choose different incoming and outgoing cast members.'; end if;
  if not exists(select 1 from public.cast_members where id=p_incoming_cast_member_id) then raise exception 'Cast member not found.'; end if;
  if exists(select 1 from public.league_roster_assignments where league_id=p_league_id and cast_member_id=p_incoming_cast_member_id) then raise exception 'This cast member is already claimed.'; end if;
  perform public.expire_league_trade_offers(p_league_id);
  if exists(select 1 from public.league_trade_offers where league_id=p_league_id and p_outgoing_cast_member_id in (initiator_cast_member_id,counterparty_cast_member_id)) then
    raise exception 'This cast member has an active trade offer.';
  end if;
  update public.league_roster_assignments set cast_member_id=p_incoming_cast_member_id,assigned_at=now()
    where league_id=p_league_id and fantasy_team_id=v_team and cast_member_id=p_outgoing_cast_member_id;
  if not found then raise exception 'The outgoing cast member is not on your team.'; end if;
end;
$$;

-- iOS/web contract: limits and category-level legal choices for every team.
-- Availability/ownership, draft turn, and authorization remain enforced by
-- existing mutation RPCs. Read access requires membership in this league.
create or replace function public.get_league_roster_rules(p_league_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_limits jsonb; v_team uuid; v_counts jsonb; v_out text; v_in text;
  v_allowed jsonb; v_choices jsonb; v_teams jsonb:='[]'; v_eligible jsonb; v_over jsonb;
  v_status text; v_candidate uuid; v_cap integer;
begin
  if auth.uid() is null or not public.is_league_member(p_league_id) then raise exception 'League membership required.'; end if;
  v_limits:=public.league_roster_limits(p_league_id);
  select status into v_status from public.leagues where id=p_league_id;
  foreach v_team in array public.league_roster_team_ids(p_league_id) loop
    v_counts:=public.league_roster_counts(p_league_id,v_team); v_allowed:='{}'; v_eligible:='{}'; v_over:='[]';
    foreach v_out in array array['Pro','Star','Bonus'] loop
      v_choices:='[]';
      if (v_counts->>v_out)::integer>0 then
        foreach v_in in array array['Pro','Star','Bonus'] loop
          if public.roster_exchange_issue(v_counts,v_limits,v_out,v_in) is null then v_choices:=v_choices||to_jsonb(v_in); end if;
        end loop;
      end if;
      v_allowed:=jsonb_set(v_allowed,array[v_out],v_choices);
      v_cap:=(v_limits->>case v_out when 'Pro' then 'pro_max' when 'Star' then 'star_max' else 'bonus_max' end)::integer;
      if not(v_limits->>'exempt')::boolean and (v_counts->>v_out)::integer>v_cap then v_over:=v_over||to_jsonb(v_out); end if;
      if v_status='drafting' then
        select c.id into v_candidate from public.cast_members c where public.league_draft_role(p_league_id,c.id) is not null
          and public.league_cast_category(public.league_draft_role(p_league_id,c.id))=v_out
          and not exists(select 1 from public.league_roster_assignments a where a.league_id=p_league_id and a.cast_member_id=c.id) limit 1;
        v_eligible:=jsonb_set(v_eligible,array[v_out],to_jsonb(v_candidate is not null and public.league_pick_is_eligible(p_league_id,v_team,v_candidate)));
      end if;
    end loop;
    v_teams:=v_teams||jsonb_build_object('team_id',v_team,'counts',v_counts,'over_limit_categories',v_over,
      'combined_active_over',not(v_limits->>'exempt')::boolean and (v_counts->>'Pro')::integer+(v_counts->>'Star')::integer>(v_limits->>'active_max')::integer,
      'allowed_exchanges',v_allowed,'draft_eligible_categories',v_eligible);
  end loop;
  return jsonb_build_object('version',1,'limits',v_limits,'teams',v_teams,'status',v_status,
    'draft_can_start',case when v_status='setup' then public.league_draft_can_finish(p_league_id) else null end,
    'roster_changes_locked',public.league_trade_airing_locked());
end;
$$;

-- All internal security-definer helpers are private. Only the two authorized
-- public RPCs are executable by clients; table writes remain RPC-only.
revoke all on function public.league_roster_team_ids(uuid),public.league_roster_limits(uuid),
  public.league_roster_counts(uuid,uuid),public.roster_exchange_issue(jsonb,jsonb,text,text),
  public.league_draft_can_finish(uuid,uuid,text),public.guard_dynamic_roster_insert(),
  public.guard_dynamic_roster_update(),public.capture_league_draft_cast_roles(),
  public.check_balanced_draft_capacity(),public.check_secondary_league_trade_role_limits(),
  public.league_pick_is_eligible(uuid,uuid,uuid),public.choose_ordered_random_draft_cast(uuid,uuid),
  public.league_category_limit(uuid,text),public.league_flex_allowance(uuid),public.league_bonus_draft_limit(uuid)
  from public,anon,authenticated;
revoke all on function public.get_league_roster_rules(uuid),public.claim_league_cast_member(uuid,uuid,uuid) from public,anon;
grant execute on function public.get_league_roster_rules(uuid),public.claim_league_cast_member(uuid,uuid,uuid) to authenticated;

commit;
notify pgrst,'reload schema';
