import assert from 'node:assert/strict';
import { isDraftAiringLocked, isDraftStartBlocked, isTradeAiringLocked } from '../week-airing-policy.js';

const week = { air_date: '2026-09-29', air_start_time: '20:00', air_end_time: '22:00', is_complete: false };
const at = (iso) => Date.parse(iso);

assert.equal(isTradeAiringLocked([week], at('2026-09-29T21:59:00Z')), false);
assert.equal(isTradeAiringLocked([week], at('2026-09-29T22:00:00Z')), true);
assert.equal(isTradeAiringLocked([week], at('2026-09-30T03:59:00Z')), true);
assert.equal(isTradeAiringLocked([week], at('2026-09-30T04:00:00Z')), false);

assert.equal(isDraftAiringLocked([week], at('2026-09-29T23:44:00Z')), false);
assert.equal(isDraftAiringLocked([week], at('2026-09-29T23:45:00Z')), false);
assert.equal(isDraftAiringLocked([week], at('2026-09-30T04:00:00Z')), false);
assert.equal(isDraftAiringLocked([{ ...week, is_complete: true }], at('2026-09-30T04:00:00Z')), false);
assert.equal(isDraftStartBlocked([week], at('2026-09-29T23:59:00Z')), false);
assert.equal(isDraftStartBlocked([week], at('2026-09-30T00:00:00Z')), true);
assert.equal(isDraftStartBlocked([{ ...week, is_complete: true }], at('2026-09-30T00:00:00Z')), false);

const delayed = { ...week, air_start_time: '21:00', air_end_time: '23:00' };
assert.equal(isTradeAiringLocked([delayed], at('2026-09-29T22:00:00Z')), false);
assert.equal(isTradeAiringLocked([delayed], at('2026-09-29T23:00:00Z')), true);
assert.equal(isDraftAiringLocked([delayed], at('2026-09-30T00:44:00Z')), false);
assert.equal(isDraftAiringLocked([delayed], at('2026-09-30T00:45:00Z')), false);

const twoNights = { ...week, second_air_date: '2026-09-30',
  second_air_start_time: '20:00', second_air_end_time: '22:00' };
assert.equal(isTradeAiringLocked([twoNights], at('2026-09-30T16:00:00Z')), false);
assert.equal(isTradeAiringLocked([twoNights], at('2026-09-30T22:00:00Z')), true);
assert.equal(isDraftAiringLocked([twoNights], at('2026-09-30T16:00:00Z')), false);
assert.equal(isDraftStartBlocked([twoNights], at('2026-09-30T16:00:00Z')), true);

console.log('Airing trade and draft windows verified.');
