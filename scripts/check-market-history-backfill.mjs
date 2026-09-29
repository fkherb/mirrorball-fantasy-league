import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../supabase/backfill-kalshi-market-history.sql', import.meta.url), 'utf8');
const points = [...sql.matchAll(/^  \('([^']+)', '(winner|second|third|top_three)', '([^']+)', '([^']+)', ([\d.]+),/gm)];
assert.equal(points.length, 128);
assert.equal(points.filter((match) => match[4] === '2026-09-14 19:59').length, 32);
assert.equal(points.filter((match) => match[4] === '2026-09-15 19:59').length, 32);
assert.equal(points.filter((match) => match[4] === '2026-09-22 19:59').length, 64);
assert.doesNotMatch(sql, /'finalist'|'elimination'/);
assert.match(sql, /to_timestamp\(candle_epoch::bigint\)/);
assert.match(sql, /on conflict \(market_ticker, snapshot_bucket\) do nothing/);
console.log('Owner-provided Week 1 and 2 backfill verified: 128 season-market points.');
