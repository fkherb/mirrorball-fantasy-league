// Fetch history only when a graph requests it. Explicit pages avoid the
// PostgREST 1,000-row response cap as a season accumulates hourly snapshots.
export async function loadMarketHistory(client, {
  castMemberId, marketKind, weekId = null, from = null, through = new Date().toISOString(),
  pageSize = 500,
}) {
  if (!castMemberId || !marketKind) throw new Error('Choose a cast member and market.');
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 1000) throw new Error('Invalid history page size.');
  const rows = [];
  for (let offset = 0; ; offset += pageSize) {
    let query = client.from('cast_market_prediction_history')
      .select('market_ticker,market_kind,week_id,snapshot_bucket,observed_at,percent,quote_source,source')
      .eq('cast_member_id', castMemberId).eq('market_kind', marketKind)
      .lte('snapshot_bucket', through)
      .order('snapshot_bucket', { ascending: true })
      .order('market_ticker', { ascending: true });
    if (weekId) query = query.eq('week_id', weekId);
    if (from) query = query.gte('snapshot_bucket', from);
    const result = await query.range(offset, offset + pageSize - 1);
    if (result.error) throw result.error;
    const page = result.data || [];
    rows.push(...page);
    if (page.length < pageSize) return rows;
  }
}
