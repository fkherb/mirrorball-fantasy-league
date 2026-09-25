# Mirrorball Fantasy League

A static GitHub Pages site for a Dancing with the Stars fantasy league. The
browser is the interface; Supabase stores the shared league data.

## How it is structured

- `index.html`, `styles.css`, `roster.css`, `app.js`, and `ui.js` are the site.
- `supabase-client.js` is the single shared Supabase browser client.
- `Images/` holds cast portraits, the DWTS logo, and judge-score graphics.
- `supabase/` contains the database migrations and policies that have been
  applied incrementally while building the league.

The Supabase publishable key in `supabase-client.js` is expected to be public.
Row-level security policies—not that key—separate public reads, league
commissioner controls, and platform-owner show administration.

## Current pages

- **Overview** shows the standings and a selected-team summary beside them on
  wider screens. On phones, selecting a team opens that summary in a compact
  detail window. League Highlights are calculated from the latest completed
  week and show its top fantasy team, cast scorer, and appearance leader.
- **My Team** appears for signed-in users. Before an account is linked it keeps
  the temporary team switcher; once `league_members.fantasy_team_id` is set, it
  displays only that account’s team and adopts the team name as its heading.
- **Dances** is the public, interactive show archive. Dance details include the
  full cast, historical fantasy-team assignments, individual point impact, and
  the team that benefited most from that dance.
- **Score Desk** lives at `/score-desk/` as a separate platform-owner workspace.
  It is the only interface that creates or changes canonical weeks, dances,
  judges' scores, cast appearances, and completed-week corrections.
- **Cast Roster Admin** lives at `/cast-roster/` and is likewise restricted to
  the platform owner. It owns canonical cast roles, partnerships, portraits,
  biographies, career highlights, and past-win information.
- **League** is the public league directory: every fantasy team, the searchable
  cast roster, and role rates. Commissioners manage league names, fantasy
  teams, assignments, and role rates without changing canonical cast facts.
- **Rules** is a compact header popup rather than a full navigation page.
- Signed-in users have first and last names. The header uses only their first
  name instead of exposing the account email; their full name remains the
  fantasy team's manager name.

## Local preview

There is no build step. Open the project through any simple static web server,
or let GitHub Pages serve the `main` branch. Do not open `index.html` directly:
the module imports and Supabase connection are designed for a web origin.

## Database notes

This is an existing, migrated project. Do **not** run `supabase/schema.sql` on
the current project: it describes the original pre-migration `players` model.

For a fresh rebuild, begin with the original schema and then apply migrations
in their documented dependency order. For this existing league, only run a new
file when its comment says it is the next needed migration.

`supabase/harden-score-desk-and-role-rates.sql` has been applied to the live
league. It adds database-level scoring safeguards, default role-rate editing,
and weekly roster snapshots.

Run `supabase/remove-completed-week-edit-lock.sql` once after it. This removes
only the old completed-week lock, leaving duplicate-dance and competing-pair
safeguards intact. A completed week then hands corrections to its Week Ledger.

Run `supabase/atomic-dance-saves-and-week-order.sql` once to enable atomic dance
saves and the inline week editor's dance reordering. It does not change existing
dances or scores. Until it is run, dance entry keeps using the older save path
and week details can still be edited, but saving a changed dance order will ask
for the migration.

Run `supabase/add-league-member-accounts.sql` before adding manager accounts.
It creates the private `league_members` account-to-team mapping, first and last
names, commissioner flag, row-level security, and a safe name-update function.
After creating users in Supabase Authentication, add one `league_members` row
per user to connect that Auth user to a fantasy team. Until this migration is
run, the existing commissioner account continues to use the legacy fallback.

Then run `supabase/refine-manager-profiles-and-cast-labels.sql`. It adds each
manager's optional My Team navigation preference, the safe manager self-edit
function, public team-manager display names, and Judge/Host subtypes. It also
converts the old Hough cast role into a Hough scoring-rate checkbox within the
Judges + Hosts category. The separate Hough role rate remains the scoring rate
used by anyone with that checkbox selected.

Finally, run `supabase/perfect-current-workflows.sql`. It is the current
hardening migration: commissioner permissions use the `league_members` role,
partnership/team/rate/deletion edits become atomic, historically referenced
cast cannot be deleted, a missing performance can be added from a completed
week's Ledger, and an optional week title remains truly blank. Run this SQL
before publishing the matching frontend changes because the site deliberately
no longer falls back to partial multi-request dance saves.

Then run `supabase/add-week-airing-dates.sql`. It adds optional first- and
second-night airing dates to each week, validates their order, and keeps those
dates in the same atomic save as week setup and dance ordering. The My Team
page shows every completed week plus only the next scheduled week; an upcoming
week displays its airing date instead of a misleading zero-point total.

Then run `supabase/edit-completed-week-details.sql`. It adds corrections for a
completed week's title, theme, airing dates, guest-judge name, and elimination
format from the Week Ledger. The database verifies that elimination settings
still match the recorded result and prevents unsafe guest-judge additions or
removals after scores have been finalized. The following migration narrows this
correction access from commissioners to the platform owner.

Finally, run `supabase/separate-platform-score-desk.sql`. It creates the private
platform-owner identity used by the separate Score Desk and moves database
write access for canonical show facts away from the league-commissioner role.
The migration seeds the current owner account from its existing Supabase Auth
email; future commissioners cannot grant themselves this permission.

Then run `supabase/separate-cast-source-and-league-settings.sql`. It moves
canonical cast editing behind the platform-owner account, gives commissioners
narrow team-assignment functions, adds public cast-profile fields and a
commissioner-editable league name, and adds a distinct season-finale marker.
The existing `is_finale` field continues to mean “no elimination”; the new
marker hides Add Week only when the last scheduled week is the season finale.

Run `supabase/restrict-mirrorball-wins-to-pros-and-houghs.sql` after that. It
limits past Mirrorball-win entry to pros (including eliminated pros) and to
Judges/Hosts with Hough scoring enabled, with the same rule enforced by the
database.

Run `supabase/fix-league-name-permissions.sql` on installations that already
applied the league-settings migration. It fixes the commissioner league-name
save path while keeping direct writes to `league_settings` blocked.

Run `supabase/add-manager-trading.sql` to enable private one-for-one trade
offers between linked manager accounts. Managers can accept, deny, or make one
counter that changes exactly one side of the offer. Accepting a trade swaps
both current team assignments atomically; completed-week snapshots remain
unchanged, and the new assignments are captured when the next week completes.

## Operational reminders

- Score Desk is the source of truth for dances, judges’ scores, and cast
  appearances.
- Create a competitive dance ahead of the show with its couple, dance type,
  and song. Judge scores may stay blank until they are announced. Use Edit on
  the week to update its details and optional one- or two-night airing dates,
  then drag dances into show order; Save changes stores everything together.
- During live scoring, edit dances, scores, and appearances normally. Mark a
  week complete only after the show: that is when the eliminated couple(s) are
  chosen. Elimination appearance rates take effect in the following week.
- Completion snapshots every cast member’s fantasy-team assignment and role
  before applying the role changes.
- Completion is a historical checkpoint, not an edit lock. The platform owner
  can correct completed-week dances, scores, and appearances in its Week Ledger.
- The Week Ledger is a platform-owner correction surface and is hidden from
  public, manager, and commissioner views.
- Trades are available only to signed-in accounts linked to fantasy teams.
  Open offers are private to the two involved managers, and accepting an offer
  invalidates any other pending offer involving either traded cast member.
- Appearance rates in Rules are league-wide: changing one recalculates every
  week. Surprise rates remain specific to each cast member in Cast Roster.
- Export or back up the Supabase data before making large commissioner edits.
