create table if not exists public.roles (id uuid primary key default gen_random_uuid(), name text not null unique, appearance_points integer, allows_custom_appearance_points boolean not null default false);
insert into public.roles (name,appearance_points,allows_custom_appearance_points) values ('Star',2,false),('Pro',1,false),('Eliminated Star',5,false),('Eliminated Pro',3,false),('Troupe',2,false),('DWTS Next Pro',3,false),('Hough',4,false),('Judges + Hosts',6,false),('Surprise',null,true) on conflict (name) do nothing;
alter table public.players add column if not exists role_id uuid references public.roles(id);
alter table public.players add column if not exists custom_appearance_points integer;
alter table public.roles enable row level security;
create policy "public read roles" on public.roles for select using (true);
