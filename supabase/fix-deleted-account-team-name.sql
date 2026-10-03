-- fix-deleted-account-team-name.sql
-- Run after account-deletion.sql.
--
-- Bug: when an account is deleted, prepare_account_deletion() renames the
-- team's manager to "Deleted account", but the enforce_team_profile_name
-- trigger immediately copies the profile's display name back (the profile
-- still exists at that point), so the former manager's real name stayed on
-- the "Former team". This skips the trigger during account deletion.
begin;

create or replace function public.enforce_team_profile_name()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_display_name text;
begin
  if coalesce(current_setting('mirrorball.deleting_account', true), '') = 'on' then
    return new;
  end if;
  select profile.display_name into v_display_name
  from public.league_members member
  join public.profiles profile on profile.user_id = member.user_id
  where member.fantasy_team_id = new.id
  limit 1;
  if v_display_name is not null then new.manager_name := v_display_name; end if;
  return new;
end;
$$;

-- Repair teams already orphaned with a real name left on them.
select set_config('mirrorball.deleting_account', 'on', true);
update public.fantasy_teams set manager_name = 'Deleted account'
where orphaned_by_account_deletion and manager_name <> 'Deleted account';

commit;
