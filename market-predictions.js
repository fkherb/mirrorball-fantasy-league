import { db } from './supabase-client.js?v=20261006-week-automation-v90';

let cached = [];
let loadedAt = 0;
let pending = null;

export async function loadMarketPredictions({ force = false } = {}) {
  if (!force && Date.now() - loadedAt < 60 * 1000) return cached;
  if (pending) return pending;
  pending = (async () => {
    const { data, error } = await db.from('cast_market_predictions')
      .select('cast_member_id,market_kind,week_id,percent,market_status,fetched_at,market_ticker')
      .in('market_status', ['active', 'open']);
    if (error) {
      // The rest of the league remains usable before the prediction migration is applied.
      if (!['42P01', 'PGRST205'].includes(error.code)) console.warn('Market predictions unavailable:', error);
      loadedAt = Date.now();
      return cached;
    }
    cached = data || [];
    loadedAt = Date.now();
    return cached;
  })().finally(() => { pending = null; });
  return pending;
}
