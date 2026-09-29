import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const baseline = await readFile(new URL('../supabase/migrations/20260929_live_public_baseline.sql', import.meta.url), 'utf8');
assert.ok(Buffer.byteLength(baseline) > 100_000, 'The live schema baseline is empty or truncated.');
for (const marker of [
  'CREATE OR REPLACE FUNCTION "public"."complete_week"',
  'CREATE OR REPLACE FUNCTION "public"."claim_league_cast_member"',
  'CREATE OR REPLACE FUNCTION "public"."guard_default_shared_trade_path"',
  'CREATE TABLE IF NOT EXISTS "public"."cast_market_prediction_history"',
  'CREATE TABLE IF NOT EXISTS "public"."league_roster_assignments"',
  'CREATE TABLE IF NOT EXISTS "public"."profiles"',
  'CREATE POLICY "profiles visible to self or league peers"',
  'CREATE POLICY "read market prediction history"',
  'ALTER DEFAULT PRIVILEGES FOR ROLE "postgres"',
]) assert.ok(baseline.includes(marker), `The live schema baseline is missing ${marker}.`);
assert.doesNotMatch(baseline, /^(?:COPY|INSERT INTO) /m, 'The baseline must remain schema-only.');
assert.doesNotMatch(baseline, /PGPASSWORD|postgres(?:ql)?:\/\//i, 'The baseline contains connection credentials.');
console.log('Live public schema baseline verified.');
