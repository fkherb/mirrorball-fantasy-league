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
Row-level security policies—not that key—restrict commissioner writes.

## Current pages

- **Overview** shows the standings and an in-page summary for the selected
  fantasy team. The League Highlights cards are intentionally a visual preview
  only; they do not query or calculate highlight data yet.
- **Teams** is the public manager view. Until manager accounts exist, anyone can
  choose a team to see its weekly history, scoring breakdown, current roster,
  and the cast members who are still available.
- **Score Desk** contains the live and completed-week scoring workflow.
- **Rules** displays the active scoring rules and appearance rates.
- **Commissioner** appears only after commissioner sign-in. It contains fantasy
  team management and the complete editable Cast Roster; it intentionally does
  not duplicate team scoring or history.

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
league. It adds database-level Score Desk safeguards, default role-rate editing,
and weekly roster snapshots.

Run `supabase/remove-completed-week-edit-lock.sql` once after it. This removes
only the old completed-week lock, leaving duplicate-dance and competing-pair
safeguards intact. A completed week then hands corrections to its Week Ledger.

Run `supabase/atomic-dance-saves-and-week-order.sql` once to enable atomic dance
saves and the inline week editor's dance reordering. It does not change existing
dances or scores. Until it is run, dance entry keeps using the older save path
and week details can still be edited, but saving a changed dance order will ask
for the migration.

## Operational reminders

- The Score Desk is the source of truth for dances, judges’ scores, and cast
  appearances.
- Create a competitive dance ahead of the show with its couple, dance type,
  and song. Judge scores may stay blank until they are announced. Use Edit on
  the week to update its details and drag dances into show order; Save changes
  stores the week and order together.
- During live scoring, edit dances, scores, and appearances normally. Mark a
  week complete only after the show: that is when the eliminated couple(s) are
  chosen. Elimination appearance rates take effect in the following week.
- Completion snapshots every cast member’s fantasy-team assignment and role
  before applying the role changes.
- Completion is a historical checkpoint, not an edit lock. Commissioners can
  correct completed-week dances, scores, and appearances in its Week Ledger.
- Appearance rates in Rules are league-wide: changing one recalculates every
  week. Surprise rates remain specific to each cast member in Cast Roster.
- Export or back up the Supabase data before making large commissioner edits.
