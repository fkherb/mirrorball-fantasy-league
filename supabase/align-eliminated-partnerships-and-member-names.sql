-- Run once after add-user-profiles.sql and harden-score-desk-and-role-rates.sql.
-- A partnership is a historical relationship; active means still competing.
-- This keeps the row (and its dance foreign keys) when either cast member is eliminated.
begin;

create or replace function public.keep_eliminated_partnership_inactive()
returns trigger language plpgsql set search_path = '' as $$
begin
  if exists (
    select 1 from public.cast_members star, public.cast_members pro
    where star.id = new.star_id and pro.id = new.pro_id
      and (star.role in ('Eliminated Star', 'Eliminated Pro')
        or pro.role in ('Eliminated Star', 'Eliminated Pro'))
  ) then
    new.active := false;
  end if;
  return new;
end;
$$;

drop trigger if exists keep_eliminated_partnership_inactive on public.partnerships;
create trigger keep_eliminated_partnership_inactive
before insert or update on public.partnerships
for each row execute function public.keep_eliminated_partnership_inactive();

create or replace function public.sync_partnership_after_cast_role_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  update public.partnerships pair
  set active = star.role = 'Star' and pro.role = 'Pro'
  from public.cast_members star, public.cast_members pro
  where pair.star_id = star.id and pair.pro_id = pro.id
    and (pair.star_id = new.id or pair.pro_id = new.id)
    and pair.active is distinct from (star.role = 'Star' and pro.role = 'Pro');
  return new;
end;
$$;

drop trigger if exists sync_partnership_after_cast_role_change on public.cast_members;
create trigger sync_partnership_after_cast_role_change
after update of role on public.cast_members
for each row when (old.role is distinct from new.role)
execute function public.sync_partnership_after_cast_role_change();

update public.partnerships pair
set active = false
from public.cast_members star, public.cast_members pro
where pair.star_id = star.id and pair.pro_id = pro.id and pair.active
  and (star.role in ('Eliminated Star', 'Eliminated Pro')
    or pro.role in ('Eliminated Star', 'Eliminated Pro'));

-- Only the account owner controls a display name. Commissioners may still
-- rename fantasy teams, but old cached clients cannot rename other people.
create or replace function public.update_team_profile_from_profile(
  p_team_id uuid, p_team_name text,
  p_manager_user_id uuid default null, p_display_name text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare v_league_id uuid := public.default_fantasy_league_id();
begin
  if auth.uid() is null or not exists (
    select 1 from public.league_members
    where league_id = v_league_id and user_id = auth.uid() and is_commissioner
  ) then raise exception 'Commissioner access is required.'; end if;
  if p_manager_user_id is not null or p_display_name is not null then
    raise exception 'Only members can change their own display names.';
  end if;
  if char_length(trim(coalesce(p_team_name, ''))) > 80 then
    raise exception 'Team name must be 80 characters or fewer.';
  end if;
  update public.fantasy_teams
  set team_name = nullif(trim(coalesce(p_team_name, '')), '')
  where id = p_team_id and league_id = v_league_id;
  if not found then raise exception 'Fantasy team not found.'; end if;
end;
$$;

commit;
notify pgrst, 'reload schema';
