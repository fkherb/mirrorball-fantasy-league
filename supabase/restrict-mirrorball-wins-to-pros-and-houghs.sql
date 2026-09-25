-- Mirrorball Fantasy League: only pros and Judges/Hosts using the Hough rate
-- may have past Mirrorball wins. Run once after
-- separate-cast-source-and-league-settings.sql.

begin;

update public.cast_members
set mirrorball_wins = 0
where mirrorball_wins <> 0
  and role not in ('Pro', 'Eliminated Pro')
  and not (role = 'Judges + Hosts' and is_hough);

alter table public.cast_members drop constraint if exists cast_members_mirrorball_wins_role_check;
alter table public.cast_members add constraint cast_members_mirrorball_wins_role_check check (
  mirrorball_wins = 0
  or role in ('Pro', 'Eliminated Pro')
  or (role = 'Judges + Hosts' and is_hough)
);

create or replace function public.update_cast_profile_details(
  p_cast_member_id uuid,
  p_bio text,
  p_career_highlights text,
  p_mirrorball_wins integer
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare v_role text; v_is_hough boolean;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if p_mirrorball_wins is null or p_mirrorball_wins < 0 or p_mirrorball_wins > 99 then raise exception 'Past wins must be from 0 to 99.'; end if;
  select role, is_hough into v_role, v_is_hough from public.cast_members where id = p_cast_member_id for update;
  if not found then raise exception 'Cast member not found.'; end if;
  if p_mirrorball_wins <> 0 and not (v_role in ('Pro','Eliminated Pro') or (v_role = 'Judges + Hosts' and v_is_hough)) then
    raise exception 'Past Mirrorball wins are available only for pros and Hough judges or hosts.';
  end if;
  update public.cast_members set bio = nullif(trim(p_bio), ''), career_highlights = nullif(trim(p_career_highlights), ''), mirrorball_wins = p_mirrorball_wins where id = p_cast_member_id;
end;
$$;

create or replace function public.save_cast_member_profile_atomic(
  p_cast_member_id uuid,
  p_name text,
  p_role text,
  p_image_path text,
  p_image_position integer,
  p_custom_appearance_points integer,
  p_role_detail text,
  p_is_hough boolean,
  p_partner_id uuid,
  p_partnership_name text,
  p_bio text,
  p_career_highlights text,
  p_mirrorball_wins integer
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare v_member_id uuid; v_wins_eligible boolean;
begin
  if not public.is_platform_admin() then raise exception 'Platform-owner access is required.'; end if;
  if p_mirrorball_wins is null or p_mirrorball_wins < 0 or p_mirrorball_wins > 99 then raise exception 'Past wins must be from 0 to 99.'; end if;
  v_wins_eligible := p_role in ('Pro','Eliminated Pro') or (p_role = 'Judges + Hosts' and coalesce(p_is_hough, false));
  if p_mirrorball_wins <> 0 and not v_wins_eligible then
    raise exception 'Past Mirrorball wins are available only for pros and Hough judges or hosts.';
  end if;
  v_member_id := public.save_cast_member_atomic(p_cast_member_id, p_name, p_role, p_image_path, p_image_position,
    p_custom_appearance_points, p_role_detail, p_is_hough, p_partner_id, p_partnership_name);
  update public.cast_members set bio = nullif(trim(p_bio), ''), career_highlights = nullif(trim(p_career_highlights), ''),
    mirrorball_wins = case when v_wins_eligible then p_mirrorball_wins else 0 end
  where id = v_member_id;
  return v_member_id;
end;
$$;

revoke all on function public.update_cast_profile_details(uuid,text,text,integer) from public, anon;
revoke all on function public.save_cast_member_profile_atomic(uuid,text,text,text,integer,integer,text,boolean,uuid,text,text,text,integer) from public, anon;
grant execute on function public.update_cast_profile_details(uuid,text,text,integer) to authenticated;
grant execute on function public.save_cast_member_profile_atomic(uuid,text,text,text,integer,integer,text,boolean,uuid,text,text,text,integer) to authenticated;

commit;
notify pgrst, 'reload schema';
