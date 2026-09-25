-- Fix an existing installation where commissioners can open the league-name
-- editor but the save RPC inherits read-only table permissions.

begin;

create or replace function public.update_league_name(p_league_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_commissioner() then
    raise exception 'Commissioner access is required.';
  end if;

  if nullif(trim(p_league_name), '') is null or char_length(trim(p_league_name)) > 80 then
    raise exception 'League name must be from 1 to 80 characters.';
  end if;

  insert into public.league_settings (id, league_name, updated_at)
  values (1, trim(p_league_name), now())
  on conflict (id) do update
    set league_name = excluded.league_name,
        updated_at = excluded.updated_at;
end;
$$;

-- The browser may read the public league name, but all writes must pass
-- through the commissioner-checked RPC above.
grant select on public.league_settings to anon, authenticated;
revoke insert, update, delete on public.league_settings from anon, authenticated;
revoke all on function public.update_league_name(text) from public, anon;
grant execute on function public.update_league_name(text) to authenticated;

commit;
