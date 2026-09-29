# Production public-schema baseline

`20260929_live_public_baseline.sql` is the **schema-only export of the live
public schema** made on September 29, 2026. It is 286,455 bytes and was checked
for the current week-completion, shared-league claim/trade, profile-policy, and
market-history definitions. `npm run check` guards against an empty, truncated,
or data-bearing replacement. The original `schema.sql` is pre-migration and
must not be copied here or applied to production.

This file is a reference baseline, **not a migration to run against the live
database**. Its short date prefix intentionally does not use Supabase's
timestamped migration naming convention. Do not rename it into an executable
migration or run `supabase db push` expecting it to apply this dump.

From the repository root, with the Supabase CLI authenticated and either its
container runtime available or a compatible local `pg_dump`, export public
schema only to a dated file here. For the CLI/container path:

```sh
SUPABASE_TELEMETRY_DISABLED=1 supabase db dump --project-ref mdrrnanxqazecqviaass --schema public --file supabase/migrations/20260929_live_public_baseline.sql
```

Do not commit an empty or partial replacement. Verify it contains the current
functions, tables, policies, and grants; compare it against the live database
after each new SQL patch. The loose `supabase/*.sql` files remain the
chronological record; do not replay them automatically over the baseline.

The export completed successfully on this Mac. A container runtime is **not**
required for the website. Keep any credentials used for future exports out of
the repository, shell history, and logs.
