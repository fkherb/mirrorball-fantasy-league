// Completed leagues share these view templates. Callers adapt their league-scoped
// database records into the same view models and keep their own action handlers.
const html = (value = '') => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const imagePosition = (value) => value != null && Number.isFinite(Number(value)) ? Number(value) : 50;
const marketLabels = { winner: 'Winner', second: '2nd Place', third: '3rd Place',
  top_three: 'Top 3', finalist: 'Finalist' };
const marketShortLabels = { winner: 'Win', second: '2nd', third: '3rd',
  top_three: 'Top 3', finalist: 'Final' };
const marketPercent = (value) => Number.isInteger(Number(value)) ? `${Number(value)}%` : `${Number(value).toFixed(1)}%`;
function predictionColor(position) {
  const stops = ['#16835e', '#84a83a', '#c38a2f', '#d36634', '#b63955'];
  const scaled = Math.max(0, Math.min(1, position)) * (stops.length - 1);
  const first = Math.floor(scaled);
  const last = Math.min(first + 1, stops.length - 1);
  const blend = scaled - first;
  const channel = (hex, offset) => Number.parseInt(hex.slice(offset, offset + 2), 16);
  return `#${[1, 3, 5].map((offset) => Math.round(channel(stops[first], offset) * (1 - blend)
    + channel(stops[last], offset) * blend).toString(16).padStart(2, '0')).join('')}`;
}
function predictionRing(percent, tone = 'season', size = '', relativePosition = 0.5) {
  const value = Math.max(0, Math.min(100, Number(percent) || 0));
  const position = Math.max(0, Math.min(1, Number(relativePosition) || 0));
  const color = predictionColor(tone === 'risk' ? position : 1 - position);
  return `<span class="prediction-ring prediction-ring-${tone}${size ? ` prediction-ring-${size}` : ''}" style="--ring-value:${value}%;--ring-color:${color}"><strong>${marketPercent(value)}</strong></span>`;
}

function marketPredictionMarkup(seasonPredictions = [], weeklyPrediction = null, weekNumber = null,
  showWeekly = false, weeklyDanceId = '') {
  if (!seasonPredictions.length && !weeklyPrediction && !showWeekly) return { main: '', desktop: '', expanded: '' };
  const best = seasonPredictions[0];
  const hasWeekly = Boolean(weeklyPrediction || showWeekly);
  const weeklyRing = weeklyPrediction
    ? predictionRing(weeklyPrediction.percent, 'risk', 'small', weeklyPrediction.relative_position)
    : '<span class="prediction-ring prediction-ring-tba prediction-ring-small"><strong>TBA</strong></span>';
  const seasonDetail = best ? `<button type="button" class="cast-profile-reveal-action" data-profile-detail="season" data-season-more aria-expanded="false" ${seasonPredictions.length > 1 ? 'aria-controls="castSeasonPredictions"' : ''} hidden><small>Season 35</small><strong>${html(marketLabels[best.market_kind])}</strong>${seasonPredictions.length > 1 ? '<span aria-hidden="true">⌄</span>' : ''}</button>` : '';
  const weeklyDetail = hasWeekly ? `<button type="button" class="cast-profile-reveal-action" data-profile-detail="weekly" ${weeklyDanceId ? `data-weekly-dance-detail="${html(weeklyDanceId)}"` : ''} hidden><small>Week ${Number(weekNumber) || ''}</small><strong>Elimination</strong>${weeklyDanceId ? '<span aria-hidden="true">›</span>' : ''}</button>` : '';
  const season = best ? `<div class="cast-market-control cast-mobile-pill" data-profile-control="season"><button type="button" class="cast-market-ring-button" data-profile-reveal="season" aria-expanded="false" aria-label="Show ${html(marketLabels[best.market_kind])} prediction">${predictionRing(best.percent, 'season', 'small', best.relative_position)}</button><button type="button" class="cast-market-short-button" data-profile-reveal="season" aria-expanded="false">${html(marketShortLabels[best.market_kind])}</button>${seasonDetail}</div>` : '';
  const weekly = hasWeekly ? `<div class="cast-market-control cast-mobile-pill" data-profile-control="weekly"><button type="button" class="cast-market-ring-button" data-profile-reveal="weekly" aria-expanded="false" aria-label="Show Week ${Number(weekNumber) || ''} elimination ${weeklyPrediction ? 'prediction' : 'TBA'}">${weeklyRing}</button><button type="button" class="cast-market-short-button" data-profile-reveal="weekly" aria-expanded="false">Elim</button>${weeklyDetail}</div>` : '';
  const expanded = seasonPredictions.length > 1 ? `<div class="cast-market-list" id="castSeasonPredictions" hidden>${seasonPredictions.slice(1).map((row) => `<span class="cast-market-mini" role="img" aria-label="${marketPercent(row.percent)} chance of ${html(marketLabels[row.market_kind])}">${predictionRing(row.percent, 'season', 'small', row.relative_position)}<span class="prediction-short-label" aria-hidden="true">${html(marketShortLabels[row.market_kind])}</span></span>`).join('')}</div>` : '';
  const desktopSeasonContent = best ? `${predictionRing(best.percent, 'season', 'small', best.relative_position)}<span class="cast-desktop-pill-copy"><small>Season 35</small><strong>${html(marketLabels[best.market_kind])}</strong></span>${seasonPredictions.length > 1 ? '<span class="cast-desktop-pill-arrow" aria-hidden="true">⌄</span>' : ''}` : '';
  const desktopSeason = best ? seasonPredictions.length > 1
    ? `<button type="button" class="cast-profile-desktop-pill cast-desktop-season-toggle" aria-expanded="false" aria-controls="castSeasonPredictions" aria-label="Show all season predictions">${desktopSeasonContent}</button>`
    : `<span class="cast-profile-desktop-pill">${desktopSeasonContent}</span>` : '';
  const desktopWeeklyContent = hasWeekly ? `${weeklyRing}<span class="cast-desktop-pill-copy"><small>Week ${Number(weekNumber) || ''}</small><strong>Elimination</strong></span>${weeklyDanceId ? '<span class="cast-desktop-pill-arrow" aria-hidden="true">›</span>' : ''}` : '';
  const desktopWeekly = hasWeekly ? weeklyDanceId
    ? `<button type="button" class="cast-profile-desktop-pill" data-weekly-dance-detail="${html(weeklyDanceId)}">${desktopWeeklyContent}</button>`
    : `<span class="cast-profile-desktop-pill">${desktopWeeklyContent}</span>` : '';
  return { main: `<section class="cast-market-predictions">${season}${weekly}</section>`, desktop: desktopSeason + desktopWeekly, expanded };
}
const predictionNote = '<p class="market-source-note">*Predictions provided by Kalshi. Predictions have no effect on fantasy points.</p>';

export function bindCastPredictionToggle(container) {
  const controls = container.querySelector('.cast-profile-controls');
  if (!controls) return;
  const seasonList = container.querySelector('#castSeasonPredictions');
  const seasonListHome = container.querySelector('.cast-market-list-home');
  const seasonMore = controls.querySelector('[data-season-more]');
  const desktopSeason = controls.querySelector('.cast-desktop-season-toggle');
  if (seasonList && seasonListHome) {
    const wideScreen = window.matchMedia('(min-width: 901px)');
    const placeSeasonList = () => {
      if (!container.isConnected) return wideScreen.removeEventListener('change', placeSeasonList);
      if (wideScreen.matches) controls.appendChild(seasonList);
      else seasonListHome.after(seasonList);
    };
    wideScreen.addEventListener('change', placeSeasonList);
    placeSeasonList();
  }
  desktopSeason?.addEventListener('click', () => {
    seasonList.hidden = !seasonList.hidden;
    desktopSeason.setAttribute('aria-expanded', String(!seasonList.hidden));
  });
  const show = (key, group) => {
    if (!group) return;
    const active = group.dataset.active === key ? '' : key;
    group.dataset.active = active;
    group.querySelectorAll('[data-profile-reveal]').forEach((button) => {
      button.setAttribute('aria-expanded', String(button.dataset.profileReveal === active));
    });
    group.querySelectorAll('[data-profile-control]').forEach((control) => {
      control.dataset.expanded = String(control.dataset.profileControl === active);
    });
    group.querySelectorAll('[data-profile-detail]').forEach((detail) => { detail.hidden = detail.dataset.profileDetail !== active; });
    if (seasonList && group.classList.contains('cast-market-predictions') && active !== 'season') {
      seasonList.hidden = true;
      seasonMore?.setAttribute('aria-expanded', 'false');
    }
  };
  controls.querySelectorAll('[data-profile-reveal]').forEach((button) => {
    button.addEventListener('click', () => show(button.dataset.profileReveal,
      button.closest('.cast-profile-meta, .cast-market-predictions')));
  });
  seasonMore?.addEventListener('click', () => {
    if (!seasonList) return show('season', seasonMore.closest('.cast-market-predictions'));
    seasonList.hidden = !seasonList.hidden;
    seasonMore.setAttribute('aria-expanded', String(!seasonList.hidden));
  });
  controls.querySelector('[data-profile-detail="weekly"]:not([data-weekly-dance-detail])')?.addEventListener('click', () => show('weekly',
    controls.querySelector('.cast-market-predictions')));
}

export function episodeSpotlight({ week, state = 'upcoming', date = '', scored = 0, performances = 0, teamPoints = null, portrait = '' }) {
  if (!week) return '';
  const title = week.title || (week.theme ? `${week.theme} Week` : `Week ${week.number}`);
  const complete = state === 'complete';
  const receiving = state === 'receiving';
  const label = complete ? 'Results are in' : receiving ? 'Scores being entered' : 'Coming up';
  const description = complete
    ? 'See the performances and how the completed show affected your league.'
    : receiving ? 'Judges’ scores are appearing. Fantasy standings update when the week is finalized.'
      : 'Explore the lineup and check back as the show unfolds.';
  const progress = performances > 0 && !complete
    ? `<div class="episode-progress"><span>${scored} of ${performances} competitive dances have scores</span><div role="progressbar" aria-label="Dances with scores" aria-valuemin="0" aria-valuemax="${performances}" aria-valuenow="${scored}"><i style="width:${Math.round(scored / performances * 100)}%"></i></div></div>` : '';
  return `<section class="episode-spotlight episode-${state}" aria-label="Featured episode"><div class="episode-spotlight-copy"><p class="eyebrow">${html(label)} · Week ${Number(week.number) || 0}${date ? ` · ${html(date)}` : ''}</p><h2>${html(title)}</h2><p>${description}</p><button type="button" data-open-episode="${html(week.id)}">${complete ? 'Explore the results' : 'Explore the episode'} <span aria-hidden="true">↗</span></button>${progress}</div><div class="episode-spotlight-aside" aria-hidden="true">${portrait ? `<img src="${html(portrait)}" alt="">` : ''}<span>DWTS</span><b>${String(Number(week.number) || 0).padStart(2, '0')}</b><small>THE SHOW</small></div>${complete && teamPoints != null ? `<div class="episode-personal-score"><small>Your team this week</small><strong>${Number(teamPoints) || 0}</strong><span>fantasy points</span></div>` : ''}</section>`;
}

export function standingsSwitch(mode, week) {
  return `<div class="standings-switch" role="group" aria-label="Standings period"><button type="button" data-standings-mode="season" aria-pressed="${mode === 'season'}" class="${mode === 'season' ? 'selected' : ''}">Season</button><button type="button" data-standings-mode="week" aria-pressed="${mode === 'week'}" class="${mode === 'week' ? 'selected' : ''}">${html(week?.title || `Week ${week?.number || ''}`)}</button></div>`;
}

export function standingCard({ id, rank, manager, name, contributors, total, selected, leader, tied, weekPoints = null, movement = null, period = 'season' }) {
  const trend = period === 'season' && weekPoints != null
    ? `<p class="standing-trend"><span>+${Number(weekPoints) || 0} latest week</span>${movement == null ? '' : `<span class="${movement > 0 ? 'up' : movement < 0 ? 'down' : ''}">${movement > 0 ? `↑ ${movement}` : movement < 0 ? `↓ ${Math.abs(movement)}` : '—'} ${movement === 0 ? 'no rank change' : movement > 0 ? 'place' + (movement === 1 ? '' : 's') + ' gained' : 'place' + (movement === -1 ? '' : 's') + ' lost'}</span>`}</p>` : '';
  return `<article class="card standing-card ${leader || tied ? 'leader' : ''} ${tied ? 'tied-leader' : ''} ${selected ? 'selected' : ''}" data-standing-team="${html(id)}" tabindex="0" role="button" aria-label="View ${html(name)} ${period === 'week' ? 'weekly' : 'season'} score breakdown"><div class="standing-rank">${rank}</div><div class="standing-main"><p class="eyebrow">${html(manager)}</p><h2>${html(name)}</h2>${tied ? '<p class="tie-note">Tied for first</p>' : ''}${trend}<div class="standing-contributors">${contributors.slice(0, 4).map(({ name: castName, points }) => `<span>${html(castName)} <b>${points}</b></span>`).join('') || '<span>No points recorded</span>'}${contributors.length > 4 ? `<span>+${contributors.length - 4} more</span>` : ''}</div></div><div class="standing-total"><strong>${total}</strong><span>${period === 'week' ? 'this week' : 'season points'}</span></div><span class="card-chevron standing-chevron" aria-hidden="true">›</span></article>`;
}

export function scoreRows(rows, { limit = null, withImages = false, imageFor = () => '', historicalJudges = false } = {}) {
  return `<div class="league-score-list">${(limit ? rows.slice(0, limit) : rows).map((row) => {
    const member = row.member;
    const hasJudges = ['Star', 'Pro'].includes(row.role) || (historicalJudges && ['Eliminated Star', 'Eliminated Pro'].includes(row.role));
    return `<div class="league-score-row ${withImages ? 'with-photo' : ''}" data-score-cast-detail="${html(member.id)}" tabindex="0" role="button">${withImages ? `<img class="score-member-photo" src="${html(castThumbnailFor(imageFor(member)))}" data-original-src="${html(imageFor(member))}" style="object-position:${imagePosition(member.image_position)}% center" alt="" loading="lazy" decoding="async">` : ''}<div class="league-score-member"><strong>${html(member.name)}</strong><span class="role-rate-pill">${html(row.displayRole || row.role)} <b>+${Number(row.appearanceRate) || 0}</b></span></div><div class="league-score-parts">${hasJudges ? `<span>Judges Total <b>${row.official || 0}</b></span>` : ''}<span class="appearance-part">Appearances <b>${row.appearances || 0}</b></span></div><strong class="league-score-total">${row.total || 0}</strong></div>`;
  }).join('') || '<p class="sub league-empty">No points recorded in this view.</p>'}</div>`;
}

export function overviewTeamDetail({ name, manager, total, castRows, period = 'season' }) {
  return `<div class="league-detail-head"><div><p class="eyebrow">Selected team</p><h2>${html(name)}</h2><p class="sub">Managed by ${html(manager)}</p></div><div class="league-detail-total"><strong>${total}</strong><span>${period === 'week' ? 'this week' : 'season points'}</span></div></div><p class="top-cast-label">Top Five Cast Members · ${period === 'week' ? 'This Week' : 'Season'}</p>${scoreRows(castRows, { limit: 5, historicalJudges: true })}`;
}

export function highlightCards({ teamScore, teamNames, castScore, castNames, appearances, appearanceNames,
  teamNamesHtml, castNamesHtml, appearanceNamesHtml }) {
  const names = (items) => `<div class="highlight-name-list">${items.map((name) => `<span>${html(name)}</span>`).join('')}</div>`;
  return `<article class="card"><small>Team of the week</small>${teamScore ? `<strong class="highlight-value">${teamScore}</strong><p>fantasy points${teamNames.length > 1 ? ' each' : ''}</p>${teamNamesHtml || names(teamNames)}` : '<p>No fantasy-team points were recorded.</p>'}</article><article class="card"><small>Top cast score</small>${castScore ? `<strong class="highlight-value">${castScore}</strong><p>points${castNames.length > 1 ? ' each' : ''}</p>${castNamesHtml || names(castNames)}` : '<p>No cast points were recorded.</p>'}</article><article class="card"><small>Most appearances</small>${appearances ? `<strong class="highlight-value">${appearances}</strong><p>dance${appearances === 1 ? '' : 's'}${appearanceNames.length > 1 ? ' each' : ''}</p>${appearanceNamesHtml || names(appearanceNames)}` : '<p>No appearances were recorded.</p>'}</article>`;
}

export function teamCard({ id, manager, name, roster, editButton = false, emptyMessage = 'No cast members assigned yet.', footerHtml = '' }) {
  return `<article class="card team-card" data-team-card-id="${html(id)}" data-team-detail="${html(id)}" tabindex="0" role="button" aria-label="View ${html(name)} cast roster"><div class="team-card-head"><div><p class="eyebrow">${html(manager)}</p><h2>${html(name)}</h2></div>${editButton ? `<button class="secondary team-edit-button" data-edit-team-id="${html(id)}">Edit</button>` : '<span class="card-chevron" aria-hidden="true">›</span>'}</div><p class="team-mobile-hint">Tap to view lineup</p>${roster.length ? `<ul class="team-roster">${roster.map((member) => `<li><span>${html(member.name)}</span><small>${html(member.role)}</small></li>`).join('')}</ul>` : `<p class="sub">${html(emptyMessage)}</p>`}${footerHtml}</article>`;
}

export function teamDetail({ manager, name, roster, imageFor, backLabel = '' }) {
  return `${backLabel ? `<button class="profile-back-button secondary" id="teamProfileBack" type="button" aria-label="Back to ${html(backLabel)}">← Back</button>` : ''}<div class="team-detail-head"><div><p class="eyebrow">${html(manager)}</p><h2>${html(name)}</h2><p class="sub">Current roster</p></div></div>${roster.length ? `<div class="team-detail-grid">${roster.map((member) => `<article class="team-detail-member" data-team-cast-detail="${html(member.id)}" tabindex="0" role="button" aria-label="View ${html(member.name)} profile"><img src="${html(castThumbnailFor(imageFor(member)))}" data-original-src="${html(imageFor(member))}" style="object-position:${imagePosition(member.image_position)}% center" alt="" loading="lazy" decoding="async"><div><b>${html(member.name)}</b><span>${html(member.displayRole || member.role)}</span></div><i aria-hidden="true">›</i></article>`).join('')}</div>` : '<p class="sub">No cast members assigned yet.</p>'}`;
}

export function castRosterRow({ id, name, roleDetails, roleDetailsHtml, image, position = 50, editButton = false }) {
  return `<div class="row cast-roster-row" data-cast-detail="${html(id)}" tabindex="0" role="button" aria-label="View ${html(name)} profile"><img class="player-photo" style="object-position:${imagePosition(position)}% center" src="${html(castThumbnailFor(image))}" data-original-src="${html(image)}" alt="" loading="lazy" decoding="async" width="70" height="80"><span><b>${html(name)}</b><small>${roleDetailsHtml ?? html(roleDetails)}</small></span>${editButton ? `<button data-player-id="${html(id)}">Edit</button>` : '<span class="row-chevron" aria-hidden="true">›</span>'}</div>`;
}

export function castThumbnailFor(image) {
  return String(image || '').replace(/^((?:\.\.\/)?Images\/)([^/]+)\.(jpe?g|png|webp)$/i, '$1Cast Thumbnails/$2.webp');
}

function judgeScoreArt(score, scoreImage, judgePhoto) {
  const portrait = judgePhoto?.(score.judge_name);
  return portrait
    ? `<span class="judge-score-art" role="img" aria-label="${html(score.judge_name)}: ${Number(score.score)}"><img src="${html(portrait)}" alt=""><b aria-hidden="true">${Number(score.score)}</b></span>`
    : `<span class="judge-score-art judge-score-paddle"><img src="${html(scoreImage(score.score))}" alt="${html(score.judge_name)}: ${Number(score.score)}"></span>`;
}

export function danceCard({ id, kind, title, danceType, song, scores, castNames, scoreImage, judgePhoto, photos = [], cardPhoto = '', poster = false, pending = false, editButton = false, weeklyPrediction = null, weekNumber = null }) {
  const total = scores.reduce((sum, score) => sum + Number(score.score || 0), 0);
  const art = photos.length
    ? `<div class="dance-card-photo"><img class="dance-photo-backdrop" src="${html(cardPhoto || photos[0])}" alt="" aria-hidden="true" loading="lazy" decoding="async"><img class="dance-photo-main" src="${html(cardPhoto || photos[0])}" alt="${html(title)} performing" loading="lazy" decoding="async"><span>${photos.length} photo${photos.length === 1 ? '' : 's'}</span></div>`
    : poster ? '<div class="dance-card-photo dance-card-poster" aria-hidden="true"><span class="poster-mark">DWTS</span><b>THE SHOW</b></div>' : '';
  const scoresMarkup = kind === 'competitive'
    ? `<div class="dance-details"><span>${html(danceType || 'Dance type not set')}</span>${song ? `<span>${html(song)}</span>` : ''}</div><div class="judge-paddles" aria-label="Judge scores">${scores.map((score) => judgeScoreArt(score, scoreImage, judgePhoto)).join('')}${scores.length ? `<strong class="dance-judge-total" aria-label="Judges total ${total}">${total}<small>judges</small></strong>` : ''}${pending ? `<span class="dance-score-pending">${scores.length ? `${scores.length} judge scores entered` : 'Awaiting scores'}</span>` : ''}</div>` : '';
  const castMarkup = castNames.length
    ? `<div class="dance-cast" title="${html(castNames.join(', '))}"><span>Cast</span>${castNames.slice(0, 3).map((name) => `<b>${html(name)}</b>`).join('')}${castNames.length > 3 ? `<b>+${castNames.length - 3}</b>` : ''}</div>` : '';
  const prediction = kind === 'competitive' && weeklyPrediction
    ? `<div class="dance-market-prediction">${predictionRing(weeklyPrediction.percent, 'risk', 'small', weeklyPrediction.relative_position)}<span class="prediction-label"><small>${weekNumber ? `Week ${Number(weekNumber)}` : 'Weekly'}</small><strong>Elimination</strong></span></div>` : '';
  return `<article class="card dance-row dance-${html(kind)} ${art ? 'has-dance-photo' : ''}" data-dance-detail="${html(id)}" tabindex="0" role="button" aria-label="View details for ${html(title)}">${art}<div class="dance-card-body"><div class="dance-card-top"><div class="dance-card-info"><p class="eyebrow">${kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h3>${html(title)}</h3></div>${editButton ? `<button class="secondary" data-edit-dance="${html(id)}">Edit</button>` : '<span class="card-chevron" aria-hidden="true">›</span>'}</div>${scoresMarkup}${prediction}${castMarkup}</div></article>`;
}

export function teamPage({ weekHistory, total, period, rosterRows, available, availableMarkup, tradesMarkup = '<section id="tradeCenter" class="trade-center card"><div class="trade-center-loading">Loading trades…</div></section>' }) {
  return `<section class="card public-team-detail"><div class="team-summary-strip"><div class="team-history-strip">${weekHistory || '<p class="sub">Weekly history will appear after scoring begins.</p>'}</div><div class="league-detail-total"><strong>${total}</strong><span>${period} points</span></div></div><div class="public-team-columns"><section><div class="public-section-head"><div><p class="eyebrow">Scoring</p><h3>Team Roster</h3></div></div>${rosterRows}</section><div class="team-side-column"><section class="available-cast-panel"><div class="public-section-head"><div><p class="eyebrow">Free agents</p><h3>Available Cast</h3></div><span>${available} available</span></div><p class="sub">Cast members not currently assigned to a fantasy team.</p><div class="league-cast-grid available-grid">${availableMarkup || '<div class="empty compact-empty">Every cast member is currently assigned.</div>'}</div></section>${tradesMarkup}</div></div></section>`;
}

export function roleRatesTable(rates, { secondaryLeague = false } = {}) {
  const order = ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro', 'Troupe', 'DWTS Next Pro', 'Hough', 'Judges + Hosts', 'Surprise'];
  const label = (name) => ({ 'Eliminated Star': 'Elim Star', 'Eliminated Pro': 'Elim Pro',
    'DWTS Next Pro': 'Next Pro', 'Judges + Hosts': 'Judge / Host' })[name] || name;
  const sorted = [...rates].sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name) || a.name.localeCompare(b.name));
  return `<div class="card role-rate-table"><div class="role-rate-heading"><span>Cast role</span><span>Appearance points</span></div>${sorted.map((rate) => `<div class="role-rate-row"><span>${html(label(rate.name))}${rate.name === 'Surprise' ? ' *' : ''}</span><strong>${rate.name === 'Surprise' || rate.appearance_points == null ? 'Varies' : `+${Number(rate.appearance_points) || 0}`}</strong></div>`).join('')}</div><p class="surprise-rate-note">${secondaryLeague ? '* Surprise cast earns its normal Bonus role’s rate +2. Surprise pros and past stars use the eliminated-role rates.' : '* Surprise cast is added as seen on the show. Its custom rate is set on that cast member.'}</p>`;
}

export function castProfile({ member, image, role, teamName, fantasyPoints, judgesTotal,
  appearanceCount, showJudges, showWins, details = [], backLabel = '', pointsLabel = 'Fantasy points', pointsNote = '',
  partnerMember = null, partnerImage = '', partnershipName = '', teamId = null, teamAvatar = '', seasonPredictions = [], weeklyPrediction = null, predictionWeekNumber = null,
  showWeeklyPrediction = false, weeklyDanceId = '' }) {
  const firstName = String(member.name || '').split(' ')[0];
  const bio = String(member.bio || 'Biography details have not been added yet.').trim();
  const words = bio.split(/\s+/);
  const longBio = words.length > 85;
  const preview = longBio ? `${words.slice(0, 65).join(' ')}…` : bio;
  const bioMarkup = `<div class="cast-bio-body"><p class="cast-bio-preview">${html(preview)}</p>${longBio ? `<details class="cast-bio-expand"><summary><span class="bio-more-label">Continue reading</span><span class="bio-less-label">Show less</span></summary><p>${html(bio)}</p></details>` : ''}</div>`;
  const partnerCard = partnerMember && ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro'].includes(member.role)
    ? `<div class="cast-mobile-pill" data-profile-control="partner"><button type="button" class="cast-profile-avatar-button" data-profile-reveal="partner" aria-expanded="false" aria-label="Show dance partner ${html(partnerMember.name)}"><img src="${html(partnerImage)}" alt=""></button><button type="button" class="cast-profile-reveal-action" data-profile-detail="partner" data-partner-profile="${html(partnerMember.id)}" hidden><strong>${html(partnerMember.name)}</strong><span aria-hidden="true">›</span></button></div>` : '';
  const teamAvatarMarkup = teamAvatar ? `<img src="${html(teamAvatar)}" alt="">` : `<span class="cast-team-initial" aria-hidden="true">${html(String(teamName || 'T').charAt(0).toUpperCase())}</span>`;
  const teamCard = teamId ? `<div class="cast-mobile-pill" data-profile-control="team"><button type="button" class="cast-profile-avatar-button" data-profile-reveal="team" aria-expanded="false" aria-label="Show ${html(teamName)} team">${teamAvatarMarkup}</button><button type="button" class="cast-profile-reveal-action" data-profile-detail="team" data-cast-team-detail="${html(teamId)}" hidden><strong>${html(teamName)}</strong><span aria-hidden="true">›</span></button></div>` : `<span class="cast-profile-available">${html(teamName || 'Available cast')}</span>`;
  const desktopTeam = teamId ? `<button type="button" class="cast-profile-desktop-pill" data-cast-team-detail="${html(teamId)}">${teamAvatarMarkup}<span class="cast-desktop-pill-copy"><strong>${html(teamName)}</strong></span><span class="cast-desktop-pill-arrow" aria-hidden="true">›</span></button>` : `<span class="cast-profile-desktop-pill cast-desktop-available">Available cast</span>`;
  const desktopPartner = partnerCard ? `<button type="button" class="cast-profile-desktop-pill" data-partner-profile="${html(partnerMember.id)}"><img src="${html(partnerImage)}" alt=""><span class="cast-desktop-pill-copy"><strong>${html(partnerMember.name)}</strong></span><span class="cast-desktop-pill-arrow" aria-hidden="true">›</span></button>` : '';
  const eliminated = member.role?.startsWith('Eliminated') ? '<p class="cast-eliminated-status">Eliminated from the competition</p>' : '';
  const predictions = member.role?.startsWith('Eliminated')
    ? { main: '', desktop: '', expanded: '' } : marketPredictionMarkup(seasonPredictions, weeklyPrediction,
      predictionWeekNumber, showWeeklyPrediction, weeklyDanceId);
  const partnershipSubtitle = ['Star', 'Pro'].includes(member.role) && partnershipName?.trim()
    ? `<p class="cast-partnership-name">${html(partnershipName.trim())}</p>` : '';
  const backButton = backLabel ? `<button class="profile-back-button secondary" id="profileBack" type="button" aria-label="Back to ${html(backLabel)}">← Back</button>` : '';
  const stats = `<div class="cast-profile-stats"><div><strong>${fantasyPoints || 0}</strong><span>${html(pointsLabel)}</span></div>${showJudges ? `<div><strong>${judgesTotal || 0}</strong><span>Judges total</span></div>` : ''}<div><strong>${appearanceCount || 0}</strong><span>Appearances</span></div>${showWins ? `<div><strong>${Number(member.mirrorball_wins) || 0}</strong><span>Past wins</span></div>` : ''}</div>`;
  const profileDetails = details.length ? `<div class="cast-profile-details">${details.map(([label, value]) => `<div><small>${html(String(label).replaceAll('_', ' '))}</small><strong>${html(value)}</strong></div>`).join('')}</div>` : '';
  const biography = `<section class="cast-profile-copy"><p class="eyebrow">Cast profile</p><h3>About ${html(firstName)}</h3>${bioMarkup}${member.career_highlights ? `<h3>Career highlights</h3><p>${html(member.career_highlights)}</p>` : ''}</section>`;
  const predictionFootnote = seasonPredictions.length || weeklyPrediction ? predictionNote : '';
  return `${backButton}<div class="cast-profile-hero"><img src="${html(image)}" style="object-position:${imagePosition(member.image_position)}% center" alt="${html(member.name)}"><div class="cast-profile-intro"><p class="eyebrow">${html(role)}</p><h2>${html(member.name)}</h2>${partnershipSubtitle}</div><div class="cast-profile-controls"><div class="cast-profile-desktop-row">${desktopTeam}${desktopPartner}${predictions.desktop}</div><div class="cast-profile-control-row"><div class="cast-profile-meta">${teamCard}${partnerCard}</div>${predictions.main}</div></div>${eliminated}</div><span class="cast-market-list-home" hidden></span>${predictions.expanded}${stats}${pointsNote ? `<p class="cast-profile-points-note">${html(pointsNote)}</p>` : ''}${biography}${profileDetails}${predictionFootnote}`;
}

export function danceDetail({ kind, title, danceType, song, scores, scoreImage, judgePhoto, teams, castRows, imageFor, photos = [], weekNumber = null, weeklyPrediction = null }) {
  const total = scores.reduce((sum, score) => sum + Number(score.score || 0), 0);
  const best = teams[0]?.points || 0;
  const leaders = best ? teams.filter((team) => team.points === best).map((team) => team.name) : [];
  const gallery = photos.length ? `<div class="dance-detail-gallery"><div class="dance-gallery-stage"><img class="dance-gallery-backdrop" src="${html(photos[0])}" alt="" aria-hidden="true" decoding="async"><img class="dance-gallery-main" src="${html(photos[0])}" alt="${html(title)} performing" decoding="async"></div>${photos.length > 1 ? `<div class="dance-gallery-rail" role="group" aria-label="Performance photos">${photos.map((photo, index) => `<button type="button" data-dance-gallery-photo="${html(photo)}" aria-label="Show photo ${index + 1} of ${photos.length}" aria-pressed="${index === 0}" class="${index === 0 ? 'selected' : ''}"><img src="${html(photo)}" alt="" loading="lazy"></button>`).join('')}</div>` : ''}</div>` : '';
  const prediction = kind === 'competitive' && weeklyPrediction
    ? `<section class="dance-detail-market">${predictionRing(weeklyPrediction.percent, 'risk', '', weeklyPrediction.relative_position)}<span class="prediction-label"><small>${weekNumber ? `Week ${Number(weekNumber)}` : 'Weekly'}</small><strong>Elimination</strong></span></section>` : '';
  return `<div class="dance-detail">${gallery}<div class="dance-detail-content"><div class="dance-detail-head"><p class="eyebrow">${weekNumber ? `Week ${Number(weekNumber)} · ` : ''}${kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h2>${html(title)}</h2><p class="sub">${kind === 'competitive' ? html(danceType || 'Dance type not set') : 'Special performance'}${song ? ` · ${html(song)}` : ''}</p></div>${prediction}${kind === 'competitive' ? `<section class="detail-section dance-score-section"><div class="detail-section-title"><h3>Judges’ scores</h3><strong>${total || '—'}</strong></div><div class="detail-judges">${scores.map((score) => `<div>${judgeScoreArt(score, scoreImage, judgePhoto)}<span>${html(score.judge_name)}</span></div>`).join('') || '<p class="sub">No scores entered.</p>'}</div></section>` : ''}${castRows.length && kind === 'competitive' ? `<section class="dance-team-spotlight"><span>Top fantasy team${leaders.length === 1 ? '' : 's'}</span><strong>${html(leaders.join(' & ') || 'No points recorded')}</strong><small>${best ? `${best} point${best === 1 ? '' : 's'} earned from this dance` : 'Fantasy impact will appear when scoring is available.'}</small></section>` : ''}<section class="detail-section"><div class="detail-section-title"><h3>Cast & fantasy impact</h3>${castRows.length ? `<span>${castRows.length} cast member${castRows.length === 1 ? '' : 's'}</span>` : ''}</div>${castRows.length ? `<div class="dance-cast-impact-list">${castRows.map((row) => `<button type="button" data-dance-cast-profile="${html(row.member.id)}"><img src="${html(imageFor(row.member))}" style="object-position:${imagePosition(row.member.image_position)}% center" alt=""><span><b>${html(row.member.name)}</b><small>${html(row.role)} · ${html(row.teamName)}</small></span><strong>${row.points ? `+${row.points}` : '—'}</strong><i aria-hidden="true">›</i></button>`).join('')}</div>` : '<p class="sub">No cast appearances were recorded for this dance.</p>'}</section>${prediction ? predictionNote : ''}</div></div>`;
}

export function bindDanceGallery(container) {
  const stage = container.querySelector('.dance-gallery-main');
  const backdrop = container.querySelector('.dance-gallery-backdrop');
  if (!stage) return;
  container.querySelectorAll('[data-dance-gallery-photo]').forEach((button) => button.addEventListener('click', () => {
    stage.src = button.dataset.danceGalleryPhoto;
    backdrop.src = stage.src;
    container.querySelectorAll('[data-dance-gallery-photo]').forEach((item) => {
      const selected = item === button;
      item.classList.toggle('selected', selected);
      item.setAttribute('aria-pressed', String(selected));
    });
  }));
}
