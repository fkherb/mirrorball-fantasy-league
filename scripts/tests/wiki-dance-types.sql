-- TEST ONLY: run in disposable fixture DB after standardize + wiki normalization.
do $$ declare name text; variant text; caught boolean:=false; begin
  for name in select t.name from public.dance_types t where t.name<>'Fusion' loop
    variant:=replace(lower(name),'-',' ');
    if public.canonical_dance_type(variant)<>name then raise exception 'Normalization failed: %',name; end if;
  end loop;
  if public.canonical_dance_type('Cha-cha-cha')<>'Cha-cha' then raise exception 'Cha-cha alias failed'; end if;
  if public.canonical_dance_type('cha cha cha / tango fusion')<>'Cha-cha/Tango Fusion' then raise exception 'Fusion alias failed'; end if;
  begin perform public.canonical_dance_type('Unknown style'); exception when others then caught:=true; end;
  if not caught then raise exception 'Unknown type was accepted'; end if;
end $$;
select 'PASS: every catalog type, Wikipedia Cha-cha-cha, Fusion aliases, unknown-type rejection' as tests;
