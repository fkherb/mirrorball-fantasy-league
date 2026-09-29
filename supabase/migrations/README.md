# Production schema baseline (pending export)

This directory is reserved for a **schema-only export of the current live
database**. No baseline has been committed yet. The original `schema.sql` is
pre-migration and must not be copied here or applied to production.

From the repository root, with the Supabase CLI authenticated and either its
container runtime available or a compatible local `pg_dump`, export public
schema only to a dated file here. For the CLI/container path:

```sh
SUPABASE_TELEMETRY_DISABLED=1 supabase db dump --project-ref mdrrnanxqazecqviaass --schema public --file supabase/migrations/20260929_live_public_baseline.sql
```

Do not commit an empty or partial file. Before committing, check it is nonzero
and contains the current `complete_week`, shared-league trade/claim functions,
profile policies, market-history table, and RLS grants. Compare it against the
live database after each new SQL patch. The loose `supabase/*.sql` files remain
the chronological record until this baseline is verified; do not replay them
automatically over the baseline.

The CLI on this Mac can authenticate to the project but delegates `db dump` to
Docker or Podman, neither of which is installed. Installing a container runtime
is **not** required for the website. A local `pg_dump` can also use credentials
from `supabase db dump --dry-run`; keep those short-lived credentials out of
the repository, shell history, and logs.
