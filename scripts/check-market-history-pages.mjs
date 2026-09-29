import assert from 'node:assert/strict';
import { loadMarketHistory } from '../market-history.js';

const data = Array.from({ length: 1205 }, (_, index) => ({
  market_ticker: 'WIN-CAST',
  snapshot_bucket: new Date(Date.UTC(2026, 0, 1, 0, index)).toISOString(),
  percent: index / 100,
}));
const requests = [];
const client = {
  from(table) {
    assert.equal(table, 'cast_market_prediction_history');
    const filters = [];
    const query = {
      select() { return query; },
      eq(field, value) { filters.push([field, value]); return query; },
      gte(field, value) { filters.push([field, value, 'gte']); return query; },
      lte(field, value) { filters.push([field, value, 'lte']); return query; },
      order() { return query; },
      range(start, end) {
        requests.push([start, end]);
        const from = filters.find(([field, , operator]) => field === 'snapshot_bucket' && operator === 'gte')?.[1];
        const through = filters.find(([field, , operator]) => field === 'snapshot_bucket' && operator === 'lte')?.[1];
        return Promise.resolve({ data: data.filter((row) => (!from || row.snapshot_bucket >= from)
          && (!through || row.snapshot_bucket <= through)).slice(start, end + 1), error: null });
      },
    };
    return query;
  },
};

const all = await loadMarketHistory(client, { castMemberId: 'cast', marketKind: 'winner',
  through: '2027-01-01T00:00:00.000Z' });
assert.equal(all.length, 1205);
assert.deepEqual(requests, [[0, 499], [500, 999], [1000, 1499]]);
assert.equal(new Set(all.map((row) => row.snapshot_bucket)).size, 1205);
const windowed = await loadMarketHistory(client, { castMemberId: 'cast', marketKind: 'winner',
  from: data[1000].snapshot_bucket, through: data[1100].snapshot_bucket });
assert.equal(windowed.length, 101);
assert.equal(windowed[0].snapshot_bucket, data[1000].snapshot_bucket);
console.log('Prediction history pages cover more than 1,000 rows without gaps.');
