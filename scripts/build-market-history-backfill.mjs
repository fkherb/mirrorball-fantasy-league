// Mechanical conversion of the supplied Kalshi candlestick notes to reviewable SQL.
// Usage: node scripts/build-market-history-backfill.mjs input.txt output.sql
import { readFileSync, writeFileSync } from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Provide the pasted source text and output SQL paths.');
const events = new Map([
  ['WINNER', ['winner', 'KXDANCINGWITHTHESTARS-26DEC31']],
  ['2ND PLACE', ['second', 'KXDWTSRANK-226DEC31']],
  ['3RD PLACE', ['third', 'KXDWTSRANK-326DEC31']],
  ['TOP 3', ['top_three', 'KXDWTSTOP3-26DEC31']],
]);
const months = new Map([['JAN', '01'], ['FEB', '02'], ['MAR', '03'], ['APR', '04'],
  ['MAY', '05'], ['JUN', '06'], ['JUL', '07'], ['AUG', '08'], ['SEP', '09'],
  ['OCT', '10'], ['NOV', '11'], ['DEC', '12']]);
const quoted = (text) => `'${text.replaceAll("'", "''")}'`;
const number = (text) => text === '-' ? 'null' : text.replace('%', '');

let observation = null;
let event = null;
const points = [];
for (const raw of readFileSync(input, 'utf8').split(/\r?\n/)) {
  const line = raw.trim();
  const date = line.match(/^# ([A-Z]{3}) (\d{1,2}), (\d{4}) @ 7:59 PM ET$/);
  if (date) {
    observation = `${date[3]}-${months.get(date[1])}-${date[2].padStart(2, '0')} 19:59`;
    if (!months.has(date[1])) throw new Error(`Unknown month: ${date[1]}`);
    continue;
  }
  if (events.has(line)) { event = events.get(line); continue; }
  const row = raw.match(/^(.+?)\s{2,}(\d+(?:\.\d+)?)%\s+(\d+(?:\.\d+)?%|-)\s+(\d+(?:\.\d+)?%|-)\s+(\d+(?:\.\d+)?%|-)\s+(\d+)\s*$/);
  if (!row) continue;
  if (!observation || !event) throw new Error(`Data row has no date or market: ${raw}`);
  const [, name, percentText, bidText, askText, lastText, candle] = row;
  const bid = bidText === '-' ? null : Number(number(bidText));
  const ask = askText === '-' ? null : Number(number(askText));
  const last = lastText === '-' ? null : Number(number(lastText));
  const percent = Number(percentText);
  const quoteSource = bid != null && ask != null ? 'midpoint' : 'last';
  if (quoteSource === 'midpoint' && Math.abs((bid + ask) / 2 - percent) > 0.01)
    throw new Error(`Midpoint mismatch: ${raw}`);
  if (quoteSource === 'last' && last !== percent)
    throw new Error(`Last-trade mismatch: ${raw}`);
  points.push([name, event[0], event[1], observation, percent, bid, ask, last, candle, quoteSource]);
}
if (points.length !== 128) throw new Error(`Expected 128 historical points; found ${points.length}.`);
const value = (point) => `  (${point.map((part) => part == null ? 'null' : typeof part === 'number' || /^\d{10}$/.test(part)
  ? String(part) : quoted(part)).join(', ')})`;
const sql = `-- Historical Kalshi snapshots supplied by the league owner; 7:59 PM Eastern before airing.
-- Source: midpoint of YES bid/ask, falling back to LAST when no spread exists.
-- Candle timestamp is retained separately from the as-of observation time.
-- Finalist and Week 1-2 elimination are intentionally absent.
-- Run after add-market-prediction-history-and-schedule.sql. Safe to rerun.
begin;
with raw(cast_name, market_kind, event_ticker, observed_local, percent,
         bid_percent, ask_percent, last_percent, candle_epoch, quote_source) as (
  values
${points.map(value).join(',\n')}
), linked as (
  select symbols.ticker_suffix, cast_member.id as cast_member_id, raw.*
  from raw
  join public.cast_members cast_member on cast_member.name = raw.cast_name
  join public.cast_market_symbols symbols on symbols.cast_member_id = cast_member.id
)
insert into public.cast_market_prediction_history (
  market_ticker, event_ticker, cast_member_id, market_kind, week_id,
  snapshot_bucket, observed_at, quote_at, percent, bid_percent,
  ask_percent, last_percent, quote_source, market_status, source
)
select event_ticker || '-' || ticker_suffix, event_ticker, cast_member_id,
  market_kind, null,
  to_timestamp(floor(extract(epoch from (observed_local::timestamp at time zone 'America/New_York')) / 3600) * 3600),
  observed_local::timestamp at time zone 'America/New_York',
  to_timestamp(candle_epoch::bigint), percent, bid_percent, ask_percent,
  last_percent, quote_source, 'historical', 'historical_backfill'
from linked
on conflict (market_ticker, snapshot_bucket) do nothing;

do $$
begin
  if (select count(*) from public.cast_market_prediction_history
      where source = 'historical_backfill') < 128 then
    raise exception 'Historical backfill is incomplete; verify cast names and ticker symbols.';
  end if;
end;
$$;
commit;
`;
writeFileSync(output, sql);
console.log(`Prepared ${points.length} historical market points.`);
