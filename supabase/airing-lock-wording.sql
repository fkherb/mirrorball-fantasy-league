-- Run once in the Supabase SQL editor (after lock-rosters-from-airing-until-week-complete.sql).
-- Shortens every airing-lock error to "… paused during airing." Only message text
-- changes: each function that contains an old message is re-created from its own
-- current definition, so its logic, owner and grants stay exactly as they are.
begin;

do $$
declare
  fn record;
  definition text;
  updated text;
begin
  for fn in
    select p.oid, p.oid::regprocedure as name
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.prosrc like '%paused from two hours before the airing until two hours after%'
        or p.prosrc like '%paused from airtime until this week is marked complete%')
  loop
    definition := pg_get_functiondef(fn.oid);
    updated := replace(replace(replace(replace(definition,
      'Trades are paused from two hours before the airing until two hours after.', 'Trades are paused during airing.'),
      'Roster changes are paused from two hours before the airing until two hours after.', 'Roster changes are paused during airing.'),
      'Trades are paused from airtime until this week is marked complete.', 'Trades are paused during airing.'),
      'Roster changes are paused from airtime until this week is marked complete.', 'Roster changes are paused during airing.');
    if updated <> definition then
      execute updated;
      raise notice 'Updated %', fn.name;
    end if;
  end loop;
end $$;

-- Anything left over would show up here (expect no rows).
select p.oid::regprocedure as still_old_wording
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and (p.prosrc like '%two hours before the airing%' or p.prosrc like '%from airtime until this week is marked complete%');

commit;
