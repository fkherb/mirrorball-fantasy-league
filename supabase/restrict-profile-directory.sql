-- Run once after activate-multi-league-workspaces.sql and add-user-profiles.sql.
-- Public league membership remains available through list_league_members;
-- this closes the otherwise enumerable profile table and directory view.
begin;

create or replace function public.can_view_profile(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and (
    p_user_id = auth.uid()
    or exists (
      select 1 from public.league_members mine
      join public.league_members theirs on theirs.league_id = mine.league_id
      where mine.user_id = auth.uid() and mine.status = 'active'
        and theirs.user_id = p_user_id and theirs.status = 'active'
    )
    or exists (
      select 1 from public.league_invites invite
      where invite.invitee_id = p_user_id and invite.status = 'pending'
        and invite.expires_at > now()
        and public.is_league_owner(invite.league_id)
    )
  );
$$;
revoke all on function public.can_view_profile(uuid) from public, anon;
grant execute on function public.can_view_profile(uuid) to authenticated;

drop policy if exists "profiles are discoverable" on public.profiles;
create policy "profiles visible to self or league peers" on public.profiles
for select to authenticated using (public.can_view_profile(user_id));

revoke select (user_id, username, display_name, avatar_url) on public.profiles from anon;
revoke select on public.profile_directory from anon;
revoke update (username, display_name, avatar_url, onboarding_completed)
  on public.profiles from authenticated;

commit;
notify pgrst, 'reload schema';
