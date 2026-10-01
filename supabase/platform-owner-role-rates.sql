-- Run once in the Supabase SQL editor before deploying the Cast Roster rate editor.
-- public.roles is the only editable rate source. The older league table is a
-- compatibility mirror, never a league-specific scoring rule.
begin;

drop policy if exists "commissioner writes roles" on public.roles;
drop policy if exists "platform owner writes roles" on public.roles;
create policy "platform owner writes roles" on public.roles for update to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

create or replace function public.update_role_rates_atomic(p_rates jsonb)
returns void language plpgsql security invoker set search_path = public as $$
declare v_rate jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Platform owner access is required.'; end if;
  if jsonb_typeof(p_rates) is distinct from 'array' then raise exception 'Role rates must be a list.'; end if;
  for v_rate in select value from jsonb_array_elements(p_rates) loop
    if coalesce(v_rate->>'name', '') = 'Surprise' then raise exception 'Surprise rates are set per cast member.'; end if;
    if coalesce(v_rate->>'appearance_points', '') !~ '^[0-9]{1,2}$' then raise exception 'Every rate must be a whole number from 0 to 99.'; end if;
    update public.roles set appearance_points = (v_rate->>'appearance_points')::integer where name = v_rate->>'name';
    if not found then raise exception 'Unknown role: %.', coalesce(v_rate->>'name', '(blank)'); end if;
  end loop;
end;
$$;

-- Reject the old per-league write endpoint, including calls from stale tabs.
create or replace function public.update_league_role_rates(p_league_id uuid, p_rates jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'League-specific role rates are no longer supported.';
end;
$$;

-- Keep older clients and snapshot creation compatible until their stored rate
-- column is retired. All values mirror the single public.roles source.
create or replace function public.sync_default_league_role_rate()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.league_role_rates (league_id, role_id, appearance_points, updated_at)
  select league.id, new.id, new.appearance_points, now() from public.leagues league
  on conflict (league_id, role_id) do update
    set appearance_points = excluded.appearance_points, updated_at = now();
  return new;
end;
$$;

insert into public.league_role_rates (league_id, role_id, appearance_points, updated_at)
select league.id, role.id, role.appearance_points, now()
from public.leagues league cross join public.roles role
on conflict (league_id, role_id) do update
  set appearance_points = excluded.appearance_points, updated_at = now();

revoke all on function public.update_role_rates_atomic(jsonb) from public, anon;
grant execute on function public.update_role_rates_atomic(jsonb) to authenticated;
revoke all on function public.update_league_role_rates(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.sync_default_league_role_rate() from public, anon, authenticated;

commit;
