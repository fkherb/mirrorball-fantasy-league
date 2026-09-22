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

`supabase/harden-score-desk-and-role-rates.sql` is intentionally **prepared but
not yet applied**. It is the next migration to run in the Supabase SQL Editor.
It adds database-level Score Desk safeguards, commissioner editing for default
role rates, completed-week protection, and weekly roster snapshots. It is safe
to wait: until the migration is applied, the site deliberately leaves the new
“Mark Complete” control hidden.

## Operational reminders

- The Score Desk is the source of truth for dances, judges’ scores, and cast
  appearances.
- During live scoring, edit dances, scores, and appearances normally. Mark a
  week complete only after the show: that is when the eliminated couple(s) are
  chosen. Elimination appearance rates take effect in the following week.
- Completion snapshots every cast member’s fantasy-team assignment and role
  before applying the role changes. Future trades therefore do not rewrite
  completed-week standings.
- A completed week is intentionally read-only. A controlled “reopen latest
  week” workflow is a future improvement; do not alter completed data directly.
- Export or back up the Supabase data before making large commissioner edits.
