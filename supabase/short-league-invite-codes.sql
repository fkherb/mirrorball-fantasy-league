-- Run after activate-multi-league-workspaces.sql, before deploying the matching UI.
-- Each setup league has one active link/code pair, valid for 48 hours.
alter table public.league_invite_links add column if not exists code_hash text;
alter table public.league_invite_links add column if not exists token_value text;
alter table public.league_invite_links add column if not exists code_value text;
create unique index if not exists league_invite_links_code_hash_idx
  on public.league_invite_links (code_hash) where code_hash is not null;
-- The existing column-level SELECT grant deliberately excludes the secret values.

create table if not exists public.league_invite_code_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index if not exists league_invite_code_attempts_user_time_idx
  on public.league_invite_code_attempts (user_id, attempted_at desc);
alter table public.league_invite_code_attempts enable row level security;
revoke all on public.league_invite_code_attempts from public, anon, authenticated;

create or replace function public.rotate_league_invite_credentials(
  p_league_id uuid, p_creator uuid
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_code text;
  v_bytes bytea;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_i integer;
  v_tries integer;
begin
  -- Internal only. Serialise code generation to make the uniqueness check safe.
  perform pg_advisory_xact_lock(hashtext('mirrorball-invite-code-generation'));
  update public.league_invite_links set revoked_at = now()
  where league_id = p_league_id and revoked_at is null;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  for v_tries in 1..10 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_code := '';
    for v_i in 0..5 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, v_i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.league_invite_links where code_hash = md5(v_code));
  end loop;
  if exists (select 1 from public.league_invite_links where code_hash = md5(v_code)) then
    raise exception 'Could not generate a unique invite code. Please try again.';
  end if;
  insert into public.league_invite_links
    (league_id, token_hash, code_hash, token_value, code_value, created_by, expires_at)
  values (p_league_id, md5(v_token), md5(v_code), v_token, v_code, p_creator,
          now() + interval '48 hours');
end;
$$;
revoke all on function public.rotate_league_invite_credentials(uuid,uuid)
  from public, anon, authenticated;

create or replace function public.initialize_league_invite_credentials()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'owner' and new.status = 'active'
     and (select status from public.leagues where id = new.league_id) = 'setup'
     and not exists (select 1 from public.league_invite_links
                     where league_id = new.league_id and revoked_at is null) then
    perform public.rotate_league_invite_credentials(new.league_id, new.user_id);
  end if;
  return new;
end;
$$;
revoke all on function public.initialize_league_invite_credentials()
  from public, anon, authenticated;
drop trigger if exists initialize_league_invite_credentials on public.league_members;
create trigger initialize_league_invite_credentials
  after insert on public.league_members for each row
  execute function public.initialize_league_invite_credentials();

-- Existing legacy links have no code; their owner receives a new pair on next open.
-- They still stop working after 48 hours from their original creation.
update public.league_invite_links
set expires_at = least(expires_at, created_at + interval '48 hours')
where revoked_at is null;

create or replace function public.get_league_invite(
  p_league_id uuid, p_refresh boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_link public.league_invite_links;
begin
  if not public.is_league_owner(p_league_id) then
    raise exception 'League owner access required.';
  end if;
  perform 1 from public.leagues where id = p_league_id for update;
  if (select status from public.leagues where id = p_league_id) <> 'setup' then
    raise exception 'Invitations are unavailable after the draft starts.';
  end if;
  select * into v_link from public.league_invite_links
  where league_id = p_league_id and revoked_at is null for update;
  if p_refresh or v_link.id is null or v_link.expires_at <= now()
     or v_link.token_value is null or v_link.code_value is null then
    perform public.rotate_league_invite_credentials(p_league_id, auth.uid());
    select * into v_link from public.league_invite_links
    where league_id = p_league_id and revoked_at is null;
  end if;
  return jsonb_build_object('token', v_link.token_value, 'code', v_link.code_value,
                            'expires_at', v_link.expires_at);
end;
$$;
revoke all on function public.get_league_invite(uuid,boolean)
  from public, anon, authenticated;
grant execute on function public.get_league_invite(uuid,boolean) to authenticated;
-- Retire the old 14-day link-only endpoints so every newly issued invite
-- follows the same 48-hour paired-code lifecycle.
revoke all on function public.regenerate_league_invite_link(uuid),
  public.revoke_league_invite_link(uuid) from public, anon, authenticated;

-- Optional scheduled rotation: Supabase projects with pg_cron enabled rotate
-- expired setup-league pairs within a minute, even if no commissioner is online.
-- get_league_invite also rotates immediately on access when pg_cron is absent.
create or replace function public.rotate_expired_league_invites()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_league record; v_count integer := 0;
begin
  for v_league in
    select league.id, league.created_by
    from public.leagues league
    left join public.league_invite_links link
      on link.league_id = league.id and link.revoked_at is null
    where league.status = 'setup'
      and (link.id is null or link.expires_at <= now() or link.code_value is null)
  loop
    perform 1 from public.leagues where id = v_league.id for update;
    if (select status from public.leagues where id = v_league.id) = 'setup'
       and not exists (
         select 1 from public.league_invite_links
         where league_id = v_league.id and revoked_at is null
           and expires_at > now() and code_value is not null
       ) then
      perform public.rotate_league_invite_credentials(v_league.id, v_league.created_by);
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;
revoke all on function public.rotate_expired_league_invites()
  from public, anon, authenticated;

do $$
declare v_cron_schema text;
begin
  select n.nspname into v_cron_schema from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_cron';
  if v_cron_schema is not null then
    begin
      execute format('select %I.schedule(%L,%L,%L)', v_cron_schema,
        'rotate-mirrorball-league-invites', '* * * * *',
        'select public.rotate_expired_league_invites()');
    exception when others then
      raise notice 'Invite rotation cron unavailable; rotation on access remains active: %', SQLERRM;
    end;
  else
    raise notice 'Enable Supabase Cron (pg_cron) for unattended invite rotation; rotation on access remains active.';
  end if;
end;
$$;

create or replace function public.join_league_with_code(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[[:space:]-]', '', 'g'));
  v_league_id uuid;
  v_league_name text;
begin
  if auth.uid() is null then raise exception 'Sign in to join a league.'; end if;
  -- Serialise attempts for this account, including simultaneous requests.
  perform 1 from public.profiles where user_id = auth.uid() for update;
  if (select count(*) from public.league_invite_code_attempts
      where user_id = auth.uid() and attempted_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('status', 'rate_limited');
  end if;
  insert into public.league_invite_code_attempts (user_id) values (auth.uid());
  if v_code !~ '^[A-HJ-NP-Z2-9]{6}$' then
    return jsonb_build_object('status', 'invalid');
  end if;
  select league.id, league.name into v_league_id, v_league_name
  from public.league_invite_links link
  join public.leagues league on league.id = link.league_id
  where link.code_hash = md5(v_code)
    and link.revoked_at is null and link.expires_at > now()
    and league.status = 'setup';
  if v_league_id is null then return jsonb_build_object('status', 'invalid'); end if;
  perform public.join_league_from_invite(v_league_id, auth.uid());
  return jsonb_build_object('status', 'joined', 'league_id', v_league_id,
                            'league_name', v_league_name);
end;
$$;
revoke all on function public.join_league_with_code(text)
  from public, anon, authenticated;
grant execute on function public.join_league_with_code(text) to authenticated;
