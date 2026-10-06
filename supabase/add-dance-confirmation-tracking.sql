-- Step 1 only: confirmation tracking. No scheduler or worker is enabled.
-- Run the entire file in Supabase SQL Editor. No dance values/scores change.
-- A song may be confirmed without an artist.
begin;

alter table public.dances
  add column if not exists dance_type_confirmed boolean not null default false,
  add column if not exists song_confirmed boolean not null default false,
  add column if not exists scores_confirmed boolean not null default false,
  add column if not exists elimination_result boolean,
  add column if not exists elimination_confirmed boolean not null default false,
  add column if not exists photos_uploaded boolean not null default false;

-- photos_uploaded starts false even for old dances: that means unverified,
-- not necessarily no existing images. Reconcile GitHub files before enabling
-- photo jobs. Only successful uploads/reconciliation may set this flag true.
-- elimination_result is an observation only, never a week-completion action.

-- Individual manually entered scores are confirmed immediately. The dance's
-- scores_confirmed flag means the entire expected judge panel is confirmed.
alter table public.dance_judge_scores
  add column if not exists confirmed boolean not null default false;

-- The future worker records candidates here, not in the actual dance fields.
-- Two distinct, consecutive successful observations of the same value are
-- needed before it imports that value. Missing/changed values reset the count.
-- Service imports must explicitly set confirmed flags after that comparison.
create table if not exists public.dance_confirmation_checks (
  dance_id uuid not null references public.dances(id) on delete cascade,
  field_name text not null check (field_name in ('dance_type', 'song', 'scores', 'elimination')),
  candidate_value jsonb,
  matching_checks integer not null default 0 check (matching_checks >= 0),
  last_check_id uuid,
  last_checked_at timestamptz,
  confirmed_source text check (confirmed_source in ('manual', 'wiki')),
  confirmed_at timestamptz,
  primary key (dance_id, field_name)
);

alter table public.dance_confirmation_checks enable row level security;
revoke all on public.dance_confirmation_checks from public, anon, authenticated;
grant select on public.dance_confirmation_checks to authenticated;
grant all on public.dance_confirmation_checks to service_role;
drop policy if exists "platform owner reads confirmation checks"
  on public.dance_confirmation_checks;
create policy "platform owner reads confirmation checks"
  on public.dance_confirmation_checks for select to authenticated
  using (public.is_platform_admin());

-- Returning this value also lets the worker require the right panel size.
create or replace function public.dance_expected_judges(p_dance_id uuid)
returns text[] language sql stable security definer set search_path = '' as $$
  select array['Carrie Ann', 'Derek', 'Bruno']::text[] ||
    case when nullif(btrim(w.guest_judge_name), '') is null then '{}'::text[]
         else array[btrim(w.guest_judge_name)] end
  from public.dances d join public.weeks w on w.id = d.week_id
  where d.id = p_dance_id and d.kind = 'competitive';
$$;

create or replace function public.refresh_dance_scores_confirmed(p_dance_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_expected text[]; v_complete boolean;
begin
  v_expected := public.dance_expected_judges(p_dance_id);
  v_complete := v_expected is not null and
    (select count(*) = cardinality(v_expected)
      and coalesce(bool_and(s.confirmed and s.judge_name = any(v_expected)), false)
     from public.dance_judge_scores s where s.dance_id = p_dance_id);
  update public.dances set scores_confirmed = v_complete
    where id = p_dance_id and scores_confirmed is distinct from v_complete;
end;
$$;

-- Seed only records not previously tracked. Rerunning this migration will NOT
-- turn later unconfirmed automated candidates into manual confirmations.
insert into public.dance_confirmation_checks
    (dance_id, field_name, confirmed_source, confirmed_at)
  select d.id, f.field_name,
    case when f.has_value then 'manual' end,
    case when f.has_value then now() end
  from public.dances d cross join lateral (values
    ('dance_type', nullif(btrim(d.dance_type), '') is not null),
    ('song', nullif(btrim(d.song), '') is not null),
    ('scores', exists (select 1 from public.dance_judge_scores s where s.dance_id = d.id))
  ) f(field_name, has_value)
  where d.kind = 'competitive'
  on conflict (dance_id, field_name) do nothing;

-- Completed weeks already have manually confirmed elimination outcomes.
-- Seed only their NEW tracking rows, without overwriting later Wiki imports.
with seeded as (
  insert into public.dance_confirmation_checks
    (dance_id, field_name, confirmed_source, confirmed_at)
  select d.id, 'elimination', case when w.is_complete then 'manual' end,
    case when w.is_complete then now() end
  from public.dances d join public.weeks w on w.id = d.week_id
  where d.kind = 'competitive'
  on conflict (dance_id, field_name) do nothing
  returning dance_id, confirmed_source
)
update public.dances d set elimination_confirmed = true,
  elimination_result = exists (
    select 1 from public.partnerships p join public.cast_members c
      on c.id in (p.star_id, p.pro_id)
    where p.id = d.partnership_id and c.eliminated_week_id = d.week_id
  )
from seeded s where s.dance_id = d.id and s.confirmed_source = 'manual';

-- Reconcile flags from tracked confirmations, also making reruns consistent.
update public.dances d set
  dance_type_confirmed = exists (select 1 from public.dance_confirmation_checks c
    where c.dance_id = d.id and c.field_name = 'dance_type' and c.confirmed_source is not null),
  song_confirmed = exists (select 1 from public.dance_confirmation_checks c
    where c.dance_id = d.id and c.field_name = 'song' and c.confirmed_source is not null)
where d.kind = 'competitive';
update public.dance_judge_scores s set confirmed = true
where exists (select 1 from public.dance_confirmation_checks c
  where c.dance_id = s.dance_id and c.field_name = 'scores' and c.confirmed_source = 'manual');
do $$ declare v_id uuid; begin
  for v_id in select id from public.dances loop
    perform public.refresh_dance_scores_confirmed(v_id);
  end loop;
end $$;

-- Website/manual SQL writes confirm entered values. Service-role writes are
-- automation: they must use the two-check importer, never this manual shortcut.
create or replace function public.mark_manual_dance_details_confirmed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() = 'service_role' then return new; end if;
  if tg_op = 'INSERT' then
    new.dance_type_confirmed := new.kind = 'competitive' and nullif(btrim(new.dance_type), '') is not null;
    new.song_confirmed := new.kind = 'competitive' and nullif(btrim(new.song), '') is not null;
    new.elimination_confirmed := new.kind = 'competitive' and new.elimination_result is not null;
  else
    if new.dance_type is distinct from old.dance_type or new.kind is distinct from old.kind then
      new.dance_type_confirmed := new.kind = 'competitive' and nullif(btrim(new.dance_type), '') is not null;
    end if;
    if new.song is distinct from old.song or new.kind is distinct from old.kind then
      new.song_confirmed := new.kind = 'competitive' and nullif(btrim(new.song), '') is not null;
    end if;
    if new.elimination_result is distinct from old.elimination_result or new.kind is distinct from old.kind then
      new.elimination_confirmed := new.kind = 'competitive' and new.elimination_result is not null;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.record_manual_dance_confirmation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_field text; v_value boolean; v_changed boolean;
begin
  if auth.role() = 'service_role' then return new; end if;
  foreach v_field in array array['dance_type', 'song', 'elimination_result'] loop
    v_changed := tg_op = 'INSERT';
    if tg_op = 'UPDATE' then
      v_changed := to_jsonb(new)->v_field is distinct from to_jsonb(old)->v_field
        or new.kind is distinct from old.kind;
    end if;
    if v_changed then
      v_value := new.kind = 'competitive' and nullif(btrim(to_jsonb(new)->>v_field), '') is not null;
      insert into public.dance_confirmation_checks
        (dance_id, field_name, confirmed_source, confirmed_at)
      values (new.id, case when v_field = 'elimination_result' then 'elimination' else v_field end,
        case when v_value then 'manual' end, case when v_value then now() end)
      on conflict (dance_id, field_name) do update set
        confirmed_source = excluded.confirmed_source, confirmed_at = excluded.confirmed_at,
        candidate_value = null, matching_checks = 0, last_check_id = null, last_checked_at = null;
    end if;
  end loop;
  return new;
end;
$$;

create or replace function public.mark_manual_judge_score_confirmed()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.role() = 'service_role' then return new; end if;
  if tg_op = 'INSERT' then new.confirmed := true;
  elsif new.score is distinct from old.score or new.judge_name is distinct from old.judge_name
    or new.dance_id is distinct from old.dance_id then new.confirmed := true;
  end if;
  return new;
end;
$$;

create or replace function public.track_judge_score_confirmation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if tg_op = 'DELETE' then v_id := old.dance_id; else v_id := new.dance_id; end if;
  -- Serialize edits to the same dance before deriving its aggregate flag.
  perform 1 from public.dances where id = v_id for update;
  perform public.refresh_dance_scores_confirmed(v_id);
  if auth.role() is distinct from 'service_role' and
    exists (select 1 from public.dances where id = v_id) then
    insert into public.dance_confirmation_checks
      (dance_id, field_name, confirmed_source, confirmed_at)
    values (v_id, 'scores', case when tg_op <> 'DELETE' then 'manual' end,
      case when tg_op <> 'DELETE' then now() end)
    on conflict (dance_id, field_name) do update set
      confirmed_source = excluded.confirmed_source, confirmed_at = excluded.confirmed_at,
      candidate_value = null, matching_checks = 0, last_check_id = null, last_checked_at = null;
  end if;
  if tg_op = 'UPDATE' and old.dance_id is distinct from new.dance_id then
    perform public.refresh_dance_scores_confirmed(old.dance_id);
  end if;
  return null;
end;
$$;

create or replace function public.refresh_week_score_confirmations()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if new.guest_judge_name is distinct from old.guest_judge_name then
    for v_id in select id from public.dances where week_id = new.id loop
      perform public.refresh_dance_scores_confirmed(v_id);
    end loop;
  end if;
  return null;
end;
$$;

drop trigger if exists mark_manual_dance_details_confirmed on public.dances;
-- The zz prefix ensures canonical dance-type normalization happens first.
drop trigger if exists zz_mark_manual_dance_details_confirmed on public.dances;
create trigger zz_mark_manual_dance_details_confirmed before insert or update of dance_type, song, kind, elimination_result
  on public.dances for each row execute function public.mark_manual_dance_details_confirmed();
drop trigger if exists record_manual_dance_confirmation on public.dances;
create trigger record_manual_dance_confirmation after insert or update of dance_type, song, kind, elimination_result
  on public.dances for each row execute function public.record_manual_dance_confirmation();
drop trigger if exists mark_manual_judge_score_confirmed on public.dance_judge_scores;
create trigger mark_manual_judge_score_confirmed before insert or update
  on public.dance_judge_scores for each row execute function public.mark_manual_judge_score_confirmed();
drop trigger if exists track_judge_score_confirmation on public.dance_judge_scores;
create trigger track_judge_score_confirmation after insert or update or delete
  on public.dance_judge_scores for each row execute function public.track_judge_score_confirmation();
drop trigger if exists refresh_week_score_confirmations on public.weeks;
create trigger refresh_week_score_confirmations after update of guest_judge_name
  on public.weeks for each row execute function public.refresh_week_score_confirmations();

revoke all on function public.dance_expected_judges(uuid),
  public.refresh_dance_scores_confirmed(uuid), public.mark_manual_dance_details_confirmed(),
  public.record_manual_dance_confirmation(), public.mark_manual_judge_score_confirmed(),
  public.track_judge_score_confirmation(), public.refresh_week_score_confirmations()
  from public, anon, authenticated;
grant execute on function public.dance_expected_judges(uuid) to service_role;

notify pgrst, 'reload schema';
commit;

-- One result row to send back after running the file.
select count(*) as competitive_dances,
  count(*) filter (where dance_type_confirmed) as dance_types_confirmed,
  count(*) filter (where song_confirmed) as songs_confirmed,
  count(*) filter (where scores_confirmed) as complete_score_panels_confirmed,
  count(*) filter (where elimination_confirmed) as elimination_results_confirmed,
  count(*) filter (where photos_uploaded) as photo_uploads_verified
from public.dances where kind = 'competitive';
