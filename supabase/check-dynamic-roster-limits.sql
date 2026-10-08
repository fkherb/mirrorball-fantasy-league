-- OPTIONAL READ-ONLY CHECK. Run in the Supabase SQL editor AFTER
-- dynamic-roster-limits.sql. Does not change any roster, score, or setting.

select l.id as league_id,l.status,l.roster_size,
  public.league_roster_limits(l.id) as roster_limits
from public.leagues l order by l.id;

with team_rules as (
  select t.league_id,t.id as team_id,
    public.league_roster_counts(t.league_id,t.id) as counts,
    public.league_roster_limits(t.league_id) as limits
  from public.fantasy_teams t
  where t.id=any(public.league_roster_team_ids(t.league_id))
)
select league_id,team_id,counts,
  case when (limits->>'exempt')::boolean then '{}'::text[] else array(
    select role from (values ('Pro','pro_max'),('Star','star_max'),('Bonus','bonus_max')) c(role,cap)
    where (counts->>role)::integer>(limits->>cap)::integer
  ) end as over_limit_categories,
  not(limits->>'exempt')::boolean and
    (counts->>'Pro')::integer+(counts->>'Star')::integer>(limits->>'active_max')::integer as combined_active_over
from team_rules order by league_id,team_id;

select
  has_function_privilege('authenticated','public.get_league_roster_rules(uuid)','EXECUTE') as client_can_read_rules,
  has_function_privilege('authenticated','public.league_draft_can_finish(uuid,uuid,text)','EXECUTE') as client_can_call_private_helper;
-- Expected privileges: true, false. Excesses in the second result are retained
-- rosters, not migration failures. The original league is always exempt.
