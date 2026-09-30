// Deploy with JWT verification disabled; this endpoint uses its own sync secret.
const seasonEvents = [
  ['winner', 'KXDANCINGWITHTHESTARS-26DEC31'],
  ['second', 'KXDWTSRANK-226DEC31'],
  ['third', 'KXDWTSRANK-326DEC31'],
  ['top_three', 'KXDWTSTOP3-26DEC31'],
  ['finalist', 'KXDWTSFINALS-31DEC26'],
] as const;

type Week = { id: string; number: number; air_date: string | null;
  second_air_date: string | null; is_complete: boolean; is_finale: boolean;
  air_start_time?: string | null; air_end_time?: string | null;
  second_air_start_time?: string | null; second_air_end_time?: string | null;
  elimination_predictions_enabled?: boolean };
type Market = { ticker: string; status: string; yes_bid_dollars: string | null;
  yes_ask_dollars: string | null; updated_time?: string | null;
  result?: string | null };

const supabaseUrl = Deno.env.get('SUPABASE_URL');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const syncSecret = Deno.env.get('MARKET_PREDICTIONS_SYNC_SECRET');
const kalshiBase = 'https://external-api.kalshi.com/trade-api/v2';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

function easternDateTime(now: number | string = Date.now()) {
  if (typeof now === 'string' && /^\d{4}-\d\d-\d\d$/.test(now)) return `${now}T00:00`;
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
    hourCycle: 'h23' }).formatToParts(new Date(now));
  const value = (part: string) => parts.find((item) => item.type === part)?.value;
  return `${value('year')}-${value('month')}-${value('day')}T${value('hour')}:${value('minute')}`;
}

function airingWindows(week: Week) {
  const windows: string[][] = [];
  if (week.air_date) windows.push([`${week.air_date}T${String(week.air_start_time || '20:00').slice(0, 5)}`,
    `${week.air_date}T${String(week.air_end_time || '22:00').slice(0, 5)}`]);
  if (week.second_air_date) windows.push([`${week.second_air_date}T${String(week.second_air_start_time || '20:00').slice(0, 5)}`,
    `${week.second_air_date}T${String(week.second_air_end_time || '22:00').slice(0, 5)}`]);
  return windows;
}

export function isWeekAiring(week: Week, now: number | string = Date.now()) {
  const clock = easternDateTime(now);
  return airingWindows(week).some(([start, end]) => clock >= start && clock < end);
}

export function eliminationEventTicker(week: Week) {
  const airDate = week.second_air_date || week.air_date;
  if (!airDate) return null;
  const dayAfter = new Date(`${airDate}T00:00:00Z`);
  if (Number.isNaN(dayAfter.getTime())) return null;
  dayAfter.setUTCDate(dayAfter.getUTCDate() + 1);
  const year = String(dayAfter.getUTCFullYear()).slice(-2);
  const month = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'][dayAfter.getUTCMonth()];
  return `KXDWTSELIMINATION-${year}${month}${String(dayAfter.getUTCDate()).padStart(2, '0')}`;
}

export function nextPredictionWeek(weeks: Week[], now: number | string = Date.now()) {
  const clock = easternDateTime(now);
  return [...weeks].sort((a, b) => a.number - b.number)
    .find((week) => (airingWindows(week).at(-1)?.[1] || '') > clock) || null;
}

function snapshotBucket(now: number, minutes: number) {
  return new Date(Math.floor(now / (minutes * 60000)) * minutes * 60000).toISOString();
}

async function supabase(path: string, init: RequestInit = {}) {
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: serviceKey!, authorization: `Bearer ${serviceKey!}`,
      'content-type': 'application/json', ...(init.headers || {}),
    },
  });
  if (!response.ok) throw new Error(`Supabase ${response.status}: ${await response.text()}`);
  if (response.status === 204 || init.method === 'POST' || init.method === 'PATCH') return null;
  return response.json();
}

async function marketsForEvent(eventTicker: string, allowMissing = false): Promise<Market[]> {
  const markets: Market[] = [];
  let cursor = '';
  do {
    const url = new URL(`${kalshiBase}/markets`);
    url.searchParams.set('event_ticker', eventTicker);
    url.searchParams.set('limit', '200');
    if (cursor) url.searchParams.set('cursor', cursor);
    let response: Response | null = null;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      response = await fetch(url, { signal: AbortSignal.timeout(15000) });
      if (response.status !== 429 && response.status < 500) break;
      await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** attempt));
    }
    if (allowMissing && response?.status === 404) return [];
    if (!response?.ok) throw new Error(`Kalshi ${response?.status || 'unavailable'} for ${eventTicker}`);
    const page = await response.json();
    if (!Array.isArray(page.markets)) throw new Error(`Invalid Kalshi response for ${eventTicker}`);
    markets.push(...page.markets);
    cursor = typeof page.cursor === 'string' ? page.cursor : '';
  } while (cursor);
  return markets;
}

function marketQuote(market: Market) {
  if (!['active', 'open'].includes(market.status)
      || market.yes_bid_dollars == null || market.yes_ask_dollars == null) return null;
  const bid = Number(market.yes_bid_dollars);
  const ask = Number(market.yes_ask_dollars);
  if (!Number.isFinite(bid) || !Number.isFinite(ask)
      || bid < 0 || ask > 1 || bid > ask) return null;
  return { percent: Math.round((bid + ask) * 500) / 10,
    bid_percent: Math.round(bid * 1000) / 10,
    ask_percent: Math.round(ask * 1000) / 10 };
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'POST required' }, 405);
  if (!supabaseUrl || !serviceKey || !syncSecret) return json({ error: 'Sync is not configured' }, 503);
  if (request.headers.get('authorization') !== `Bearer ${syncSecret}`) return json({ error: 'Unauthorized' }, 401);
  try {
    const now = Date.now();
    const [symbols, weeks, cast, pairs, syncStates] = await Promise.all([
      supabase('cast_market_symbols?select=cast_member_id,ticker_suffix'),
      supabase('weeks?select=*&order=number.asc'),
      supabase('cast_members?select=id,role,eliminated_week_id'),
      supabase('partnerships?select=star_id,pro_id,active&active=eq.true'),
      supabase('market_prediction_sync_state?select=id,refreshed_at,snapshot_bucket&id=eq.1'),
    ]);
    const airing = (weeks as Week[]).some((week) => isWeekAiring(week, now));
    const intervalMinutes = airing ? 5 : 15;
    const state = syncStates?.[0];
    const forced = (await request.json().catch(() => ({})))?.force === true;
    if (!forced && state?.refreshed_at
        && snapshotBucket(Date.parse(state.refreshed_at), intervalMinutes) === snapshotBucket(now, intervalMinutes)) {
      return json({ skipped: true, next_interval_minutes: intervalMinutes });
    }

    const castById = new Map<string, { role: string; eliminated_week_id?: string | null }>(cast.map((member: { id: string; role: string; eliminated_week_id?: string | null }) => [member.id, member]));
    const activeStars = new Set<string>(pairs.filter((pair: { star_id: string; pro_id: string }) =>
      castById.get(pair.star_id)?.role === 'Star' && castById.get(pair.pro_id)?.role === 'Pro'
      && !castById.get(pair.star_id)?.eliminated_week_id && !castById.get(pair.pro_id)?.eliminated_week_id)
      .map((pair: { star_id: string }) => pair.star_id));
    const bySuffix = new Map<string, string>(symbols.filter((item: { cast_member_id: string }) =>
      activeStars.has(item.cast_member_id)).map((item: { ticker_suffix: string; cast_member_id: string }) =>
      [item.ticker_suffix, item.cast_member_id]));

    const week = nextPredictionWeek(weeks as Week[], now);
    const weeklyTicker = week && !week.is_complete && !week.is_finale && week.elimination_predictions_enabled
      ? eliminationEventTicker(week) : null;
    const events: Array<{ kind: string; ticker: string; weekId: string | null }> = seasonEvents
      .map(([kind, ticker]) => ({ kind, ticker, weekId: null }));
    if (weeklyTicker) events.push({ kind: 'elimination', ticker: weeklyTicker, weekId: week!.id });

    const fetchedAt = new Date(now).toISOString();
    const rows = [];
    const bucket = snapshotBucket(now, airing ? 10 : 60);
    const shouldSnapshot = !state?.snapshot_bucket || Date.parse(state.snapshot_bucket) !== Date.parse(bucket);
    const history = [];
    for (const event of events) {
      const markets = await marketsForEvent(event.ticker, event.kind === 'elimination');
      for (const market of markets) {
        if (!market.ticker.startsWith(`${event.ticker}-`)) continue;
        const castId = bySuffix.get(market.ticker.slice(event.ticker.length + 1));
        if (!castId) continue;
        const quote = marketQuote(market);
        rows.push({ market_ticker: market.ticker, event_ticker: event.ticker,
          cast_member_id: castId, market_kind: event.kind, week_id: event.weekId,
          percent: quote?.percent ?? null, bid_percent: quote?.bid_percent ?? null,
          ask_percent: quote?.ask_percent ?? null, quote_source: quote ? 'midpoint' : null,
          market_status: market.status, market_result: market.result || null, fetched_at: fetchedAt });
        if (shouldSnapshot && quote) history.push({ market_ticker: market.ticker,
          event_ticker: event.ticker, cast_member_id: castId, market_kind: event.kind,
          week_id: event.weekId, snapshot_bucket: bucket, observed_at: fetchedAt,
          quote_at: market.updated_time || null, ...quote, last_percent: null,
          quote_source: 'midpoint', market_status: market.status, source: 'live' });
      }
    }
    if (rows.length) await supabase('cast_market_predictions?on_conflict=market_ticker', {
      method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(rows),
    });
    if (history.length) await supabase('cast_market_prediction_history?on_conflict=market_ticker,snapshot_bucket', {
      method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
      body: JSON.stringify(history),
    });
    await supabase('market_prediction_sync_state?id=eq.1', {
      method: 'PATCH', headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ refreshed_at: fetchedAt, ...(history.length ? { snapshot_bucket: bucket } : {}) }),
    });
    return json({ updated: rows.length, snapshotted: history.length,
      weekly_event: weeklyTicker, fetched_at: fetchedAt, next_interval_minutes: intervalMinutes });
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : 'Prediction sync failed' }, 502);
  }
});
