-- Run after standardize-dance-types.sql. Changes validation only: no dance
-- values or confirmation flags are updated by this migration.
begin;
create or replace function public.canonical_dance_type(p_value text)
returns text language plpgsql stable security invoker set search_path = '' as $$
declare v_value text := nullif(btrim(p_value), '');
  v_parts text[]; v_type text; v_first text; v_second text; v_key text;
begin
  if v_value is null then return null; end if;
  v_key := regexp_replace(lower(v_value), '[^a-z0-9]', '', 'g');
  if v_key = 'chachacha' then v_key := 'chacha'; end if;
  select name into v_type from public.dance_types
    where regexp_replace(lower(name), '[^a-z0-9]', '', 'g') = v_key and name <> 'Fusion';
  if v_type is not null then return v_type; end if;
  v_parts := regexp_match(v_value, '^([^/]+)/([^/]+)[[:space:]]+Fusion$', 'i');
  if v_parts is null then
    raise exception 'Choose a listed dance type, or select two styles for Fusion.' using errcode = 'P0001';
  end if;
  v_first := public.canonical_dance_type(btrim(v_parts[1]));
  v_second := public.canonical_dance_type(btrim(v_parts[2]));
  if v_first is null or v_second is null or v_first = v_second then
    raise exception 'Fusion needs two different listed dance types.' using errcode = 'P0001';
  end if;
  return v_first || '/' || v_second || ' Fusion';
end;
$$;
revoke all on function public.canonical_dance_type(text) from public, anon;
grant execute on function public.canonical_dance_type(text) to authenticated, service_role;
notify pgrst, 'reload schema';
commit;

select public.canonical_dance_type('Cha-cha-cha') as cha_cha,
  public.canonical_dance_type('Viennese waltz') as viennese_waltz,
  public.canonical_dance_type('hip hop') as hip_hop,
  public.canonical_dance_type('cha cha cha / tango fusion') as fusion;
