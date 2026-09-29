import assert from 'node:assert/strict';

const calls = [];
let handler;
let currentTime = Date.parse('2099-10-01T00:05:00Z'); // Sep 30, 8:05 PM Eastern.
let syncState = { id: 1, refreshed_at: null, snapshot_bucket: null };
let weeklyMarketAvailable = true;
const weeks = [{ id: 'week-3', number: 3, air_date: '2099-09-29',
  second_air_date: '2099-09-30', is_complete: false, is_finale: false,
  air_start_time: '20:00:00', air_end_time: '22:00:00',
  second_air_start_time: '20:00:00', second_air_end_time: '22:00:00',
  elimination_predictions_enabled: true }];
const cast = [{ id: 'star-tat', role: 'Star' }, { id: 'pro-jan', role: 'Pro' },
  { id: 'star-eliminated', role: 'Eliminated Star' }, { id: 'pro-eliminated', role: 'Eliminated Pro' }];
const realDateNow = Date.now;
Date.now = () => currentTime;
globalThis.Deno = {
  env: { get: (key) => ({ SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'service-test', MARKET_PREDICTIONS_SYNC_SECRET: 'sync-test' })[key] },
  serve: (fn) => { handler = fn; },
};
const originalFetch = globalThis.fetch;
globalThis.fetch = async (input, init = {}) => {
  const url = new URL(String(input));
  calls.push({ url, init });
  if (url.hostname === 'example.supabase.co') {
    const table = url.pathname.split('/').at(-1);
    if (table === 'cast_market_symbols') return Response.json([
      { cast_member_id: 'star-tat', ticker_suffix: 'TAT' },
      { cast_member_id: 'star-eliminated', ticker_suffix: 'ELI' },
    ]);
    if (table === 'weeks') return Response.json(weeks);
    if (table === 'cast_members') return Response.json(cast);
    if (table === 'partnerships') return Response.json([
      { star_id: 'star-tat', pro_id: 'pro-jan', active: true },
      { star_id: 'star-eliminated', pro_id: 'pro-eliminated', active: true },
    ]);
    if (table === 'market_prediction_sync_state') {
      if (init.method === 'PATCH') {
        syncState = { ...syncState, ...JSON.parse(init.body) };
        return new Response(null, { status: 204 });
      }
      return Response.json([syncState]);
    }
    if (['cast_market_predictions', 'cast_market_prediction_history'].includes(table)) {
      return new Response(null, { status: 201 });
    }
  }
  if (url.hostname === 'external-api.kalshi.com') {
    const event = url.searchParams.get('event_ticker');
    if (event?.startsWith('KXDWTSELIMINATION') && !weeklyMarketAvailable) {
      return new Response(null, { status: 404 });
    }
    return Response.json({ markets: [
      { ticker: `${event}-TAT`, status: 'open',
        yes_bid_dollars: '0.3300', yes_ask_dollars: '0.3400' },
      { ticker: `${event}-ELI`, status: 'open',
        yes_bid_dollars: '0.0100', yes_ask_dollars: '0.0200' },
    ], cursor: '' });
  }
  throw new Error(`Unexpected URL ${url}`);
};

try {
  const { nextPredictionWeek, eliminationEventTicker, isWeekAiring } =
    await import('../supabase/functions/sync-market-predictions/index.ts');
  assert.equal(eliminationEventTicker(weeks[0]), 'KXDWTSELIMINATION-99OCT01');
  assert.equal(nextPredictionWeek(weeks, '2099-09-30')?.id, 'week-3');
  assert.equal(nextPredictionWeek(weeks, Date.parse('2099-10-01T02:00:00Z')), null);
  assert.equal(isWeekAiring(weeks[0], currentTime), true);
  assert.equal(isWeekAiring(weeks[0], Date.parse('2099-10-01T02:00:00Z')), false);
  const denied = await handler(new Request('https://sync.example', { method: 'POST' }));
  assert.equal(denied.status, 401);

  const request = () => new Request('https://sync.example', { method: 'POST',
    headers: { authorization: 'Bearer sync-test' } });
  const first = await handler(request());
  assert.equal(first.status, 200);
  const result = await first.json();
  assert.equal(result.weekly_event, 'KXDWTSELIMINATION-99OCT01');
  assert.equal(result.next_interval_minutes, 5);
  assert.equal(result.updated, 6);
  assert.equal(result.snapshotted, 6);
  const saved = calls.find((call) => call.url.pathname.endsWith('/cast_market_predictions'));
  const rows = JSON.parse(saved.init.body);
  assert.equal(rows.find((row) => row.market_kind === 'elimination').week_id, 'week-3');
  assert.equal(rows.find((row) => row.market_kind === 'elimination').percent, 33.5);
  assert(rows.every((row) => row.cast_member_id === 'star-tat'));
  const history = JSON.parse(calls.find((call) => call.url.pathname.endsWith('/cast_market_prediction_history')).init.body);
  assert.equal(history.length, 6);
  assert(history.every((row) => row.quote_source === 'midpoint' && row.bid_percent === 33));

  currentTime += 5 * 60 * 1000;
  assert.equal((await (await handler(request())).json()).snapshotted, 6);
  assert.equal((await (await handler(request())).json()).skipped, true);
  weeks[0].elimination_predictions_enabled = false;
  currentTime += 5 * 60 * 1000;
  const disabled = await (await handler(request())).json();
  assert.equal(disabled.weekly_event, null);
  assert.equal(disabled.updated, 5);

  weeks[0].elimination_predictions_enabled = true;
  weeklyMarketAvailable = false;
  currentTime += 5 * 60 * 1000;
  const missing = await (await handler(request())).json();
  assert.equal(missing.weekly_event, 'KXDWTSELIMINATION-99OCT01');
  assert.equal(missing.updated, 5);
  weeklyMarketAvailable = true;
  currentTime = Date.parse('2099-10-01T02:05:00Z'); // The second airing is over.
  const after = await (await handler(request())).json();
  assert.equal(after.weekly_event, null);
  assert.equal(after.next_interval_minutes, 15);
  assert.equal(after.updated, 5);

  cast[0].role = 'Eliminated Star';
  currentTime += 15 * 60 * 1000;
  const eliminated = await (await handler(request())).json();
  assert.equal(eliminated.updated, 0);
  assert.equal(eliminated.snapshotted, 0);
  console.log('Kalshi sync cadence, snapshots, active-couple filtering, and weekly transition verified.');
} finally {
  globalThis.fetch = originalFetch;
  Date.now = realDateNow;
}
