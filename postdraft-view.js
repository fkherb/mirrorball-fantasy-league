// Completed leagues share these view templates. Callers adapt their league-scoped
// database records into the same view models and keep their own action handlers.
const html = (value = '') => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const imagePosition = (value) => value != null && Number.isFinite(Number(value)) ? Number(value) : 50;

export function standingCard({ id, rank, manager, name, contributors, total, selected, leader, tied }) {
  return `<article class="card standing-card ${leader || tied ? 'leader' : ''} ${tied ? 'tied-leader' : ''} ${selected ? 'selected' : ''}" data-standing-team="${html(id)}" tabindex="0" role="button" aria-label="View ${html(name)} score breakdown"><div class="standing-rank">${rank}</div><div class="standing-main"><p class="eyebrow">${html(manager)}</p><h2>${html(name)}</h2>${tied ? '<p class="tie-note">Tied for first</p>' : ''}<div class="standing-contributors">${contributors.slice(0, 4).map(({ name: castName, points }) => `<span>${html(castName)} <b>${points}</b></span>`).join('') || '<span>No cast assigned</span>'}${contributors.length > 4 ? `<span>+${contributors.length - 4} more</span>` : ''}</div></div><div class="standing-total"><strong>${total}</strong><span>points</span></div><span class="card-chevron standing-chevron" aria-hidden="true">›</span></article>`;
}

export function scoreRows(rows, { limit = null, withImages = false, imageFor = () => '', historicalJudges = false } = {}) {
  return `<div class="league-score-list">${(limit ? rows.slice(0, limit) : rows).map((row) => {
    const member = row.member;
    const hasJudges = ['Star', 'Pro'].includes(row.role) || (historicalJudges && ['Eliminated Star', 'Eliminated Pro'].includes(row.role));
    return `<div class="league-score-row ${withImages ? 'with-photo' : ''}" data-score-cast-detail="${html(member.id)}" tabindex="0" role="button">${withImages ? `<img class="score-member-photo" src="${html(imageFor(member))}" style="object-position:${imagePosition(member.image_position)}% center" alt="">` : ''}<div class="league-score-member"><strong>${html(member.name)}</strong><span class="role-rate-pill">${html(row.displayRole || row.role)} <b>+${Number(row.appearanceRate) || 0}</b></span></div><div class="league-score-parts">${hasJudges ? `<span>Judges Total <b>${row.official || 0}</b></span>` : ''}<span class="appearance-part">Appearances <b>${row.appearances || 0}</b></span></div><strong class="league-score-total">${row.total || 0}</strong></div>`;
  }).join('') || '<p class="sub league-empty">No points recorded in this view.</p>'}</div>`;
}

export function overviewTeamDetail({ name, manager, total, castRows }) {
  return `<div class="league-detail-head"><div><p class="eyebrow">Selected team</p><h2>${html(name)}</h2><p class="sub">Managed by ${html(manager)}</p></div><div class="league-detail-total"><strong>${total}</strong><span>season points</span></div></div><p class="top-cast-label">Top Five Cast Members</p>${scoreRows(castRows, { limit: 5, historicalJudges: true })}`;
}

export function highlightCards({ teamScore, teamNames, castScore, castNames, appearances, appearanceNames,
  teamNamesHtml, castNamesHtml, appearanceNamesHtml }) {
  const names = (items) => `<div class="highlight-name-list">${items.map((name) => `<span>${html(name)}</span>`).join('')}</div>`;
  return `<article class="card"><small>Team of the week</small>${teamScore ? `<strong class="highlight-value">${teamScore}</strong><p>fantasy points${teamNames.length > 1 ? ' each' : ''}</p>${teamNamesHtml || names(teamNames)}` : '<p>No fantasy-team points were recorded.</p>'}</article><article class="card"><small>Top cast score</small>${castScore ? `<strong class="highlight-value">${castScore}</strong><p>points${castNames.length > 1 ? ' each' : ''}</p>${castNamesHtml || names(castNames)}` : '<p>No cast points were recorded.</p>'}</article><article class="card"><small>Most appearances</small>${appearances ? `<strong class="highlight-value">${appearances}</strong><p>dance${appearances === 1 ? '' : 's'}${appearanceNames.length > 1 ? ' each' : ''}</p>${appearanceNamesHtml || names(appearanceNames)}` : '<p>No appearances were recorded.</p>'}</article>`;
}

export function teamCard({ id, manager, name, roster, editButton = false, emptyMessage = 'No cast members assigned yet.', footerHtml = '' }) {
  return `<article class="card team-card" data-team-card-id="${html(id)}" data-team-detail="${html(id)}" tabindex="0" role="button" aria-label="View ${html(name)} cast roster"><div class="team-card-head"><div><p class="eyebrow">${html(manager)}</p><h2>${html(name)}</h2></div>${editButton ? `<button class="secondary team-edit-button" data-edit-team-id="${html(id)}">Edit</button>` : '<span class="card-chevron" aria-hidden="true">›</span>'}</div><p class="team-mobile-hint">Tap to view lineup</p>${roster.length ? `<ul class="team-roster">${roster.map((member) => `<li><span>${html(member.name)}</span><small>${html(member.role)}</small></li>`).join('')}</ul>` : `<p class="sub">${html(emptyMessage)}</p>`}${footerHtml}</article>`;
}

export function castRosterRow({ id, name, roleDetails, roleDetailsHtml, image, position = 50, editButton = false }) {
  return `<div class="row cast-roster-row" data-cast-detail="${html(id)}" tabindex="0" role="button" aria-label="View ${html(name)} profile"><img class="player-photo" style="object-position:${imagePosition(position)}% center" src="${html(image)}" alt=""><span><b>${html(name)}</b><small>${roleDetailsHtml ?? html(roleDetails)}</small></span>${editButton ? `<button data-player-id="${html(id)}">Edit</button>` : '<span class="row-chevron" aria-hidden="true">›</span>'}</div>`;
}

export function danceCard({ id, kind, title, danceType, song, scores, castNames, scoreImage, pending = false, editButton = false }) {
  return `<article class="card dance-row dance-${html(kind)}" data-dance-detail="${html(id)}" tabindex="0" role="button" aria-label="View details for ${html(title)}"><div class="dance-card-top"><div class="dance-card-info"><p class="eyebrow">${kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h3>${html(title)}</h3></div>${editButton ? `<button class="secondary" data-edit-dance="${html(id)}">Edit</button>` : '<span class="card-chevron" aria-hidden="true">›</span>'}</div>${kind === 'competitive' ? `<div class="dance-details"><span>${html(danceType || 'Dance type not set')}</span>${song ? `<span>${html(song)}</span>` : ''}</div><div class="judge-paddles" aria-label="Judge scores">${scores.map((score) => `<img src="${html(scoreImage(score.score))}" alt="${html(score.judge_name)}: ${Number(score.score)}">`).join('')}${pending ? `<span class="dance-score-pending">${scores.length ? `${scores.length} judge scores entered` : 'Awaiting scores'}</span>` : ''}</div>` : ''}${castNames.length ? `<div class="dance-cast" title="${html(castNames.join(', '))}"><span>Cast</span>${castNames.slice(0, 3).map((name) => `<b>${html(name)}</b>`).join('')}${castNames.length > 3 ? `<b>+${castNames.length - 3}</b>` : ''}</div>` : ''}</article>`;
}

export function teamPage({ weekHistory, total, period, rosterRows, available, availableMarkup, tradesMarkup = '<section id="tradeCenter" class="trade-center card"><div class="trade-center-loading">Loading trades…</div></section>' }) {
  return `<section class="card public-team-detail"><div class="team-summary-strip"><div class="team-history-strip">${weekHistory || '<p class="sub">Weekly history will appear after scoring begins.</p>'}</div><div class="league-detail-total"><strong>${total}</strong><span>${period} points</span></div></div><div class="public-team-columns"><section><div class="public-section-head"><div><p class="eyebrow">Scoring</p><h3>Team Roster</h3></div></div>${rosterRows}</section><div class="team-side-column"><section class="available-cast-panel"><div class="public-section-head"><div><p class="eyebrow">Free agents</p><h3>Available Cast</h3></div><span>${available} available</span></div><p class="sub">Cast members not currently assigned to a fantasy team.</p><div class="league-cast-grid available-grid">${availableMarkup || '<div class="empty compact-empty">Every cast member is currently assigned.</div>'}</div></section>${tradesMarkup}</div></div></section>`;
}
