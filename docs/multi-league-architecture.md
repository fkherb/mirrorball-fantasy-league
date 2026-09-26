# Multi-league readiness plan

> This file is design documentation, not SQL. The executable first-stage
> migration is `supabase/prepare-multi-league-foundation.sql`.

## Goal

Prepare the application to support multiple independent fantasy leagues while keeping one platform-owned source of truth for the DWTS cast, partnerships, weeks, dances, judges' scores, and appearances. This plan does not create another league or expose league creation in the interface.

## Data ownership boundary

Platform-owned show data stays global and is edited only through the Cast Roster and Score Desk:

- cast members and profile information
- partnerships
- weeks and airing details
- dances, judges' scores, and appearances

League-owned data must be scoped by a league:

- league name and settings
- commissioners and managers
- fantasy teams and their rosters
- appearance-point rates and other scoring options
- trades and trade history
- completed-week roster and rate snapshots

The same cast member can therefore belong to a different fantasy team in each league without duplicating the cast member or any show results.

## Target schema

### `leagues`

Create one row for the existing league before any other league can exist.

- `id uuid primary key`
- `slug text unique not null`
- `name text not null`
- `created_by uuid not null`
- `status text not null` (`active`, `archived`)
- timestamps

The singleton `league_settings` record should become a league-keyed settings table, or its current fields can move into `leagues` if they are all league metadata.

### `league_members`

Change membership from a single global league relationship to:

- `league_id uuid not null`
- `user_id uuid not null`
- `role text not null` (`commissioner`, `manager`, or `member`)
- `fantasy_team_id uuid null`
- profile and navigation-label fields that are specific to that league
- unique `(league_id, user_id)`

`platform_admins` remains separate. A platform owner is not implicitly a commissioner of every league.

### `fantasy_teams`

Add `league_id uuid not null`. Team names need only be unique within a league, if they are made unique at all. A team must never reference a manager membership from another league.

### `league_roster_assignments`

This is the required structural change. `cast_members.fantasy_team_id` currently allows only one global owner and cannot support multiple leagues.

Create a league-specific assignment table with:

- `league_id uuid not null`
- `fantasy_team_id uuid not null`
- `cast_member_id uuid not null`
- acquisition and release timestamps, or an explicit active-period model
- unique current assignment for `(league_id, cast_member_id)`

All claims, releases, trades, team displays, and current standings should read this table. After migration is verified, remove `cast_members.fantasy_team_id`.

### Scoring settings and snapshots

Keep the role catalog global, but store configurable rates in `league_role_rates (league_id, role_id, appearance_points)`. Completed-week snapshots must include `league_id` and have a unique key such as `(league_id, week_id, cast_member_id)`.

Fantasy scoring then becomes:

1. Read canonical show results once.
2. Join each completed week to that league's roster snapshot.
3. Apply that league's snapshotted scoring rates.

This keeps historical results stable even after a trade or a later rule change.

### Trades

Add `league_id` to active offers and history. Database functions must verify that:

- both teams belong to the supplied league;
- both cast assignments are current in that league;
- the signed-in manager controls the expected team in that league;
- a trade cannot cross leagues;
- accept, counter, deny, cancel, expiration, and invalidation write history in the same transaction.

## Authorization design

Every league mutation should receive or derive a `league_id` and enforce access in the database. Shared helper functions should answer questions such as:

- is this user a member of this league?
- does this user manage this team in this league?
- is this user a commissioner of this league?

Row-level security should include `league_id` in every league-owned policy. Client-provided team IDs must never be treated as authorization. Platform-only cast and show mutations remain protected by `platform_admins`.

## Application routing and state

Introduce a league context in the URL before showing any league-creation controls, for example `/leagues/dwts-fantasy-league` or `?league=dwts-fantasy-league`. The URL is the source of truth; local storage may remember the last visited league only as a convenience.

All league data loaders should accept the active league ID explicitly. The Score Desk and Cast Roster remain platform pages and do not switch leagues.

## Safe migration sequence

1. **Inventory and backup** — record row counts and constraints for teams, members, assignments, snapshots, trades, and rates.
2. **Create the league boundary** — add `leagues`, seed exactly one row for the current league, add nullable `league_id` columns, and backfill every existing league-owned row.
3. **Add league roster assignments** — backfill from `cast_members.fantasy_team_id`; add temporary compatibility reads or dual writes so the live site remains functional.
4. **Scope history and rules** — add and backfill `league_id` on snapshots, rates, trade offers, and trade history.
5. **Replace database functions and policies** — make every RPC and row-level policy league-aware, with cross-league rejection tests.
6. **Add frontend league context** — route all existing screens through the seeded league while keeping the user experience unchanged.
7. **Enforce the new model** — make league IDs non-null, add composite uniqueness and foreign keys, stop dual writes, and remove `cast_members.fantasy_team_id` only after parity checks pass.
8. **Future release** — separately design league creation, invitations, league switching, defaults, and archive/delete behavior. Do not enable these during the schema-readiness migration.

## Verification gates

Before each stage advances:

- current standings and every completed week match the pre-migration totals;
- every team retains the same roster and manager;
- active and historical trades retain their state;
- a manager cannot read private data or mutate another league;
- commissioners cannot edit platform-owned cast or show data;
- the current league continues to load without requiring a new user choice;
- rollback scripts and row-count checks are ready before destructive cleanup.

The migration should be delivered as staged, idempotent SQL files rather than one large script. The first production release should still contain only the existing league.
