// Mirrors dynamic-roster-limits.sql for instant previews. The database remains
// authoritative; get_league_roster_rules also exposes its allowed categories.
export const rosterCategory = (role) => ['Pro', 'Star'].includes(role) ? role : 'Bonus';
const categories = ['Pro', 'Star', 'Bonus'];

export function calculateRosterLimits(pros, stars, teamCount, rosterSize) {
  const count = Math.max(1, teamCount);
  const active = Math.ceil((pros + stars) / count);
  const role = Math.ceil((pros + stars) / count / 2);
  return { pro_max: role, star_max: role, active_max: active,
    bonus_max: Math.max(0, rosterSize - active + 1), roster_size: rosterSize, team_count: count };
}

export function rosterCounts(members) {
  const counts = { Pro: 0, Star: 0, Bonus: 0 };
  for (const member of members) counts[rosterCategory(member.role)]++;
  return counts;
}

export function rosterExchangeIssue(counts, limits, outgoing, incoming) {
  if (limits.exempt) return '';
  if (!categories.includes(outgoing) || !categories.includes(incoming) || !counts[outgoing]) return 'Choose a cast member on your roster.';
  const caps = { Pro: limits.pro_max, Star: limits.star_max, Bonus: limits.bonus_max };
  const over = categories.filter((role) => counts[role] > caps[role]);
  const combinedOver = counts.Pro + counts.Star > limits.active_max;
  if (over.length || combinedOver) {
    if (over.length ? !over.includes(outgoing) : outgoing === 'Bonus') return 'Release or offer cast only from an over-limit category.';
    if (incoming === outgoing || over.includes(incoming)) return 'Choose an incoming category with room; this exchange must reduce an excess.';
    if (combinedOver && incoming !== 'Bonus') return 'Too many Pros and Stars combined: exchange an active member for Bonus cast.';
  }
  const after = { ...counts, [outgoing]: counts[outgoing] - 1 };
  after[incoming]++;
  for (const role of categories) if (after[role] > Math.max(caps[role], counts[role])) return `This exchange would exceed the ${role} limit of ${caps[role]}.`;
  if (after.Pro + after.Star > Math.max(limits.active_max, counts.Pro + counts.Star)) return `This exchange would exceed the combined Pro/Star limit of ${limits.active_max}.`;
  return '';
}

export function allowedExchangeCategories(counts, limits) {
  return Object.fromEntries(categories.map((outgoing) => [outgoing,
    categories.filter((incoming) => !rosterExchangeIssue(counts, limits, outgoing, incoming))]));
}

// Integral max flow: the shared active edge enforces Pro+Star together, while
// separate role edges and the Bonus edge protect every remaining roster slot.
export function draftCanFinish(pool, teams, limits) {
  const size = 5 + teams.length * 2;
  const sink = size - 1;
  const edges = Array.from({ length: size }, () => Array(size).fill(0));
  categories.forEach((role, index) => { edges[0][index + 1] = pool[role]; });
  let demand = 0;
  for (let i = 0; i < teams.length; i++) {
    const counts = teams[i], activeNode = 4 + 2 * i, teamNode = activeNode + 1;
    const remaining = limits.roster_size - counts.Pro - counts.Star - counts.Bonus;
    if (remaining < 0 || counts.Pro > limits.pro_max || counts.Star > limits.star_max
        || counts.Bonus > limits.bonus_max || counts.Pro + counts.Star > limits.active_max) return false;
    edges[1][activeNode] = limits.pro_max - counts.Pro;
    edges[2][activeNode] = limits.star_max - counts.Star;
    edges[3][teamNode] = limits.bonus_max - counts.Bonus;
    edges[activeNode][teamNode] = limits.active_max - counts.Pro - counts.Star;
    edges[teamNode][sink] = remaining;
    demand += remaining;
  }
  let flow = 0;
  while (flow < demand) {
    const parent = Array(size).fill(-1), queue = [0];
    parent[0] = 0;
    for (let q = 0; q < queue.length && parent[sink] < 0; q++) {
      const from = queue[q];
      for (let to = 0; to < size; to++) if (parent[to] < 0 && edges[from][to] > 0) {
        parent[to] = from; queue.push(to);
      }
    }
    if (parent[sink] < 0) return false;
    let amount = demand - flow;
    for (let to = sink; to !== 0; to = parent[to]) amount = Math.min(amount, edges[parent[to]][to]);
    for (let to = sink; to !== 0; to = parent[to]) {
      edges[parent[to]][to] -= amount; edges[to][parent[to]] += amount;
    }
    flow += amount;
  }
  return true;
}

export function draftCategoryEligibility(pool, teams, teamIndex, limits) {
  return Object.fromEntries(categories.map((role) => {
    if (!pool[role] || teamIndex < 0) return [role, false];
    const after = teams.map((counts) => ({ ...counts }));
    after[teamIndex][role]++;
    return [role, draftCanFinish({ ...pool, [role]: pool[role] - 1 }, after, limits)];
  }));
}
