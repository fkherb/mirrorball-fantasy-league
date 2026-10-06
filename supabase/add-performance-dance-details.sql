-- Run once in Supabase SQL Editor before publishing the performance editor.
-- Existing competitive songs and historical scoring remain unchanged.
begin;

alter table public.dances add column if not exists choreography text;

create or replace function public.update_performance_dance_details(
  p_dance_id uuid,
  p_song text,
  p_choreography text
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Platform-owner access is required.';
  end if;

  update public.dances
  set song = nullif(trim(p_song), ''),
      choreography = nullif(trim(p_choreography), '')
  where id = p_dance_id and kind = 'performance';

  if not found then
    raise exception 'Performance dance not found.';
  end if;
end;
$$;

revoke all on function public.update_performance_dance_details(uuid,text,text) from public, anon;
grant execute on function public.update_performance_dance_details(uuid,text,text) to authenticated;

commit;
