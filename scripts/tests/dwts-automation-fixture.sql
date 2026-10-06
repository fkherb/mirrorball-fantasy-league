-- TEST ONLY: use a brand-new disposable database, NEVER live Supabase.
create schema auth;
create function auth.role() returns text language sql stable as $$ select nullif(current_setting('test.auth_role',true),'') $$;
create function public.is_platform_admin() returns boolean language sql as $$ select false $$;
create table public.weeks(id uuid primary key default gen_random_uuid(), number integer unique, is_complete boolean default false, is_finale boolean default false, guest_judge_name text, air_date date, second_air_date date, air_start_time time default '00:00',air_end_time time default '23:59',second_air_start_time time,second_air_end_time time);
create table public.cast_members(id uuid primary key default gen_random_uuid(),name text,eliminated_week_id uuid);
create table public.partnerships(id uuid primary key default gen_random_uuid(),star_id uuid,pro_id uuid);
create table public.dances(id uuid primary key default gen_random_uuid(),week_id uuid references public.weeks,kind text,partnership_id uuid references public.partnerships,dance_type text,song text,sort_order integer default 0);
create table public.dance_judge_scores(id uuid primary key default gen_random_uuid(),dance_id uuid references public.dances on delete cascade,judge_name text,score integer,unique(dance_id,judge_name));
create function public.canonical_dance_type(t text) returns text language plpgsql as $$ begin
  if t is null then return null; end if;
  if lower(t) not in ('rumba','jive') then raise exception 'Unknown type'; end if;
  return initcap(t);
end $$;
insert into public.weeks(number,is_complete,air_date) values(3,true,current_date-7),(4,false,(now() at time zone 'America/New_York')::date);
-- Put the test clock inside both the photo/live and post-show windows.
update public.weeks set air_start_time=((now() at time zone 'America/New_York')-interval '1 hour')::time,
  air_end_time=((now() at time zone 'America/New_York')+interval '10 minutes')::time where number=4;
insert into public.cast_members(name) values('Amber Glenn'),('Pasha Pashkov'),('Connor Wood'),('Rylee Arnold');
insert into public.partnerships(star_id,pro_id) select s.id,p.id from public.cast_members s join public.cast_members p on (s.name='Amber Glenn' and p.name='Pasha Pashkov') or (s.name='Connor Wood' and p.name='Rylee Arnold');
insert into public.dances(week_id,kind,partnership_id) select w.id,'competitive',p.id from public.weeks w cross join public.partnerships p;
insert into public.dances(week_id,kind) select id,'performance' from public.weeks;
