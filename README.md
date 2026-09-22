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
not yet applied**. It adds database-level score-desk safeguards and permission
to edit default role rates. Run it in the Supabase SQL Editor only when the
commissioner is ready.

## Operational reminders

- The Score Desk is the source of truth for dances, judges’ scores, and cast
  appearances.
- A fantasy-team assignment is current-state data. Before implementing real
  trades, add weekly roster snapshots/history so a trade does not rewrite old
  standings.
- Export or back up the Supabase data before making large commissioner edits.
