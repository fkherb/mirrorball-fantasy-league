-- Run in the Supabase SQL editor before deploying the Score Desk dropdown.
-- Safe to run after the earlier nine-type version of this file.
-- To add another type later: insert into public.dance_types (name) values ('New Type');
begin;

create table if not exists public.dance_types (
  name text primary key check (name = btrim(name) and length(name) between 1 and 80)
);

insert into public.dance_types (name) values
  ('Argentine Tango'), ('Cha-cha'), ('Charleston'), ('Contemporary'),
  ('Foxtrot'), ('Freestyle'), ('Fusion'), ('Hip-Hop'), ('Jazz'), ('Jive'),
  ('Mambo'), ('Paso Doble'), ('Quickstep'), ('Rumba'), ('Salsa'),
  ('Samba'), ('Tango'), ('Viennese Waltz'), ('Waltz')
on conflict (name) do nothing;

alter table public.dance_types drop constraint if exists dance_types_simple_name;
alter table public.dance_types add constraint dance_types_simple_name
  check (name !~ '/' and (name = 'Fusion' or name !~ ' Fusion$'));
create unique index if not exists dance_types_name_ci_idx on public.dance_types (lower(name));

-- A single stored string keeps existing dance cards and the save RPC compatible.
-- The validator accepts catalog names or two distinct catalog names joined as
-- "First/Second Fusion", and stores canonical spelling for every component.
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

-- Normalize the live Cha-Cha variant and any other casing differences.
-- Existing null values remain unset for upcoming competitive dances.
update public.dances set dance_type = public.canonical_dance_type(dance_type)
where dance_type is not null;

-- An earlier version used a single-name FK; Fusion needs validated pairs.
alter table public.dances drop constraint if exists dances_dance_type_catalog_fkey;

create or replace function public.check_dance_type_catalog()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.dance_type := public.canonical_dance_type(new.dance_type);
  if new.kind = 'performance' and new.dance_type is not null then
    raise exception 'Only competitive dances have a dance type.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
drop trigger if exists check_dance_type_catalog on public.dances;
create trigger check_dance_type_catalog before insert or update of dance_type, kind
  on public.dances for each row execute function public.check_dance_type_catalog();

alter table public.dances drop constraint if exists dances_performance_without_type;
alter table public.dances add constraint dances_performance_without_type
  check (kind <> 'performance' or dance_type is null);

alter table public.dance_types enable row level security;
drop policy if exists "public read dance types" on public.dance_types;
create policy "public read dance types" on public.dance_types for select to anon, authenticated using (true);
revoke all on public.dance_types from anon, authenticated;
grant select on public.dance_types to anon, authenticated;
grant select on public.dance_types to service_role;
revoke all on function public.canonical_dance_type(text) from public, anon;
grant execute on function public.canonical_dance_type(text) to authenticated, service_role;
revoke all on function public.check_dance_type_catalog() from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
