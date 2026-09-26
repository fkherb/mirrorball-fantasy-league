import { db } from './supabase-client.js';
import { renderLeagueHub, renderSecondaryLeague, stopSecondaryLeague } from './league-workspace.js?v=20260926-account-menu-refresh';
const $ = (selector) => document.querySelector(selector);
const appSurface = document.body.dataset.surface || 'league';
const isScoreDeskSurface = appSurface === 'score-desk';
const isCastRosterSurface = appSurface === 'cast-roster';
const isOwnerSurface = isScoreDeskSurface || isCastRosterSurface;
const defaultLeagueId = '00000000-0000-4000-8000-000000000001';
let activeLeagueId = defaultLeagueId;
const assetRoot = isOwnerSurface ? '../' : '';
const roles = ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro', 'Troupe', 'DWTS Next Pro', 'Judges + Hosts', 'Surprise'];
const assignableRoles = roles.filter((role) => !role.startsWith('Eliminated'));
const storedImagePathFor = (name) => `Images/${name.replace(/[.,'’]/g, '')}.jpg`;
const imagePathFor = (name) => `${assetRoot}${storedImagePathFor(name)}`;
const imageFallback = `data:image/svg+xml;charset=UTF-8,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80"><rect width="80" height="80" rx="12" fill="#eee8ed"/><circle cx="40" cy="29" r="14" fill="#c9bdc6"/><path d="M15 76c2-18 12-28 25-28s23 10 25 28" fill="#c9bdc6"/></svg>')}`;
const displayImagePath = (member) => {
  const storedPath = member?.image_path;
  if (!storedPath) return imagePathFor(member?.name || '');
  if (/^(?:https?:|data:|\/|\.\.\/)/i.test(storedPath)) return storedPath;
  return `${assetRoot}${storedPath.replace(/^\.\//, '')}`;
};
document.addEventListener('error', (event) => {
  const image = event.target;
  if (!(image instanceof HTMLImageElement) || image.dataset.fallbackApplied) return;
  image.dataset.fallbackApplied = 'true';
  image.src = imageFallback;
}, true);
const isPairRole = (role) => role === 'Star' || role === 'Pro';
const isAnyPairRole = (role) => ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro'].includes(role);
const canHaveMirrorballWins = (role, isHough = false) => ['Pro', 'Eliminated Pro'].includes(role) || (role === 'Judges + Hosts' && isHough);
const oppositeRole = (role) => role === 'Star' ? 'Pro' : 'Star';
const activePairRole = (role) => role.includes('Star') ? 'Star' : role.includes('Pro') ? 'Pro' : role;
const judgeScoreImage = (score) => `${assetRoot}Images/Judges Scores/${score}.png?v=20260921-optimized`;
let canEdit = false;
let canManageShow = false;
let canManageCast = false;
let rosterFilter = 'all';
let selectedWeekId = null;
let editingWeekId = null;
let standingsSnapshot = null;
let selectedOverviewTeamId = null;
let selectedPublicTeamId = null;
let selectedPublicWeekId = 'all';
let managerTeamId = null;
let managerFirstName = '';
let managerLastName = '';
let managerDisplayName = '';
let managerTeamName = '';
let managerNavLabelMode = 'default';
let managerCustomNavLabel = '';
let supportsDatabaseHardening = false;
let scoreDeskLoadVersion = 0;
let tradeViewMode = 'active';
let tradeCountdownTimer = null;
let tradeLoadVersion = 0;
const loadVersions = { roster: 0, teams: 0, standings: 0, settings: 0, rules: 0 };

const friendlyError = (context = 'complete that request') => `We couldn’t ${context}. Please try again.`;
const loadingMarkup = (label = 'Loading') => `<div class="loading-state" role="status" aria-live="polite"><span class="loading-shimmer"></span><span class="loading-shimmer"></span><span class="loading-shimmer short"></span><p>${escapeHtml(label)}…</p></div>`;

function showNotice(message, title = 'Something went wrong') {
  const dialog = $('#modal');
  if (!dialog) return;
  if (dialog.open && $('#modalBody')?.textContent.trim()) {
    dialog.querySelector('.inline-notice-overlay')?.remove();
    dialog.insertAdjacentHTML('beforeend', `<div class="inline-notice-overlay" role="alertdialog" aria-modal="true"><div><p class="eyebrow">${escapeHtml(title)}</p><h2>${escapeHtml(message)}</h2><div class="modal-actions"><button type="button" data-dismiss-inline-notice>Close</button></div></div></div>`);
    dialog.querySelector('[data-dismiss-inline-notice]').addEventListener('click', () => dialog.querySelector('.inline-notice-overlay').remove());
    return;
  }
  openModal(`<div class="notice-dialog" role="alert"><p class="eyebrow">${escapeHtml(title)}</p><h2>${escapeHtml(message)}</h2><div class="modal-actions"><button id="dismissNotice" type="button">Close</button></div></div>`);
  $('#dismissNotice')?.addEventListener('click', () => dialog.close());
}

function openConfirmation({ title, message, confirmLabel = 'Confirm', destructive = false, onConfirm, onCancel = null }) {
  openModal(`<div class="confirm-dialog"><p class="eyebrow">Please confirm</p><h2>${escapeHtml(title)}</h2><p class="sub">${escapeHtml(message)}</p><p id="confirmActionError" class="sub error" hidden></p><div class="modal-actions"><button id="cancelConfirmation" type="button" class="secondary">Cancel</button><button id="confirmAction" type="button" class="${destructive ? 'danger' : ''}">${escapeHtml(confirmLabel)}</button></div></div>`);
  $('#cancelConfirmation').addEventListener('click', () => onCancel ? onCancel() : $('#modal').close());
  $('#confirmAction').addEventListener('click', async () => {
    const button = $('#confirmAction');
    button.disabled = true;
    const original = button.textContent;
    button.textContent = 'Working…';
    try {
      const error = await onConfirm();
      if (error) throw error;
      $('#modal').close();
    } catch (error) {
      button.disabled = false;
      button.textContent = original;
      $('#confirmActionError').hidden = false;
      $('#confirmActionError').textContent = friendlyError('complete this action');
      console.error(error);
    }
  });
}

async function withBusy(button, busyLabel, action) {
  if (!button || button.disabled) return;
  const original = button.textContent;
  button.disabled = true;
  button.textContent = busyLabel;
  try { return await action(); }
  finally { if (button.isConnected) { button.disabled = false; button.textContent = original; } }
}

function renderLoadError(container, context, retry) {
  if (!container) return;
  container.innerHTML = `<div class="card empty error-state"><b>${escapeHtml(friendlyError(context))}</b><button type="button" class="secondary">Try again</button></div>`;
  container.querySelector('button')?.addEventListener('click', retry);
}

function displayRole(memberOrRole) {
  const member = typeof memberOrRole === 'string' ? { role: memberOrRole } : memberOrRole || {};
  if (member.role === 'Eliminated Pro') return 'Elim Pro';
  if (member.role === 'Eliminated Star') return 'Elim Star';
  if (member.role === 'DWTS Next Pro') return 'Next Pro';
  if (member.role === 'Judges + Hosts') return member.role_detail || 'Judge + Host';
  return member.role || '';
}

async function getTeamManagerMap() {
  const { data, error } = await db.rpc('get_league_team_managers');
  if (error) { console.error(error); return new Map(); }
  return new Map((data || []).map((person) => [person.fantasy_team_id, { ...person, name: person.display_name || [person.first_name, person.last_name].filter(Boolean).join(' ') }]));
}

function managerNameFor(team, managerMap) {
  return managerMap?.get(team.id)?.name || team.manager_name;
}

function defaultTeamName(managerName) {
  const firstName = String(managerName || '').trim().split(/\s+/)[0];
  return `${firstName || 'Manager'}'s Team`;
}

function castCategory(player) {
  if (player.role === 'Pro' || player.role === 'Eliminated Pro') return 'pros';
  if (player.role === 'Star' || player.role === 'Eliminated Star') return 'stars';
  return 'bonus';
}
function bonusCastCategory(player) {
  if (player.role === 'Troupe') return 'troupe';
  if (player.role === 'DWTS Next Pro') return 'nextpro';
  return 'judges';
}

function showRosterMessage(message, isError = false) {
  $('#rosterResults').innerHTML = `<p class="sub ${isError ? 'error' : ''}">${escapeHtml(message)}</p>`;
}

function openModal(contents) {
  const dialog = $('#modal');
  $('#modalBody').innerHTML = `<div class="modal">${contents}</div>`;
  dialog.dataset.dirty = 'false';
  if (!dialog.open) dialog.showModal();
  const requestClose = () => {
    if (dialog.dataset.dirty !== 'true') return dialog.close();
    if (dialog.querySelector('.discard-prompt')) return;
    dialog.insertAdjacentHTML('beforeend', '<div class="discard-prompt" role="alertdialog" aria-modal="true"><div><h2>Discard unsaved changes?</h2><p>Anything you entered in this window will be lost.</p><div class="modal-actions"><button type="button" class="secondary" data-keep-editing>Keep editing</button><button type="button" class="danger" data-discard-changes>Discard</button></div></div></div>');
    dialog.querySelector('[data-keep-editing]').addEventListener('click', () => dialog.querySelector('.discard-prompt').remove());
    dialog.querySelector('[data-discard-changes]').addEventListener('click', () => dialog.close());
  };
  $('#modalClose').onclick = requestClose;
  dialog.oncancel = (event) => { event.preventDefault(); requestClose(); };
  $('#modalBody').oninput = (event) => { if (event.target.matches('input,select,textarea')) dialog.dataset.dirty = 'true'; };
  $('#modalBody').onchange = (event) => { if (event.target.matches('input,select,textarea')) dialog.dataset.dirty = 'true'; };
}

function escapeHtml(value = '') {
  return String(value).replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
}

// Keep technical database details out of the member-facing interface while
// preserving concise validation messages written specifically for managers.
window.alert = (message) => {
  const text = String(message || '');
  const publicText = text.startsWith('Couldn’t') && text.includes(':') ? `${text.split(':')[0]}. Please try again.` : text;
  showNotice(publicText, text.startsWith('Couldn’t') ? 'Please try again' : 'Heads up');
};

document.addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button || button.disabled) return;
  if (button.dataset.clickLock === 'true') { event.preventDefault(); event.stopImmediatePropagation(); return; }
  button.dataset.clickLock = 'true';
  window.setTimeout(() => { if (button.isConnected) delete button.dataset.clickLock; }, 700);
}, true);

async function getPairingData() {
  const [{ data: players, error: playerError }, { data: partnerships, error: pairingError }, { data: weeks, error: weekError }, { data: teams, error: teamError }, managerMap] = await Promise.all([
    db.from('cast_members').select('*').order('name'),
    db.from('partnerships').select('id,star_id,pro_id,active,partnership_name').eq('active', true),
    db.from('weeks').select('id,number,label').order('number', { ascending: false }),
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('league_id', defaultLeagueId),
    getTeamManagerMap(),
  ]);
  if (playerError || pairingError || weekError || teamError) throw new Error(playerError?.message || pairingError?.message || weekError?.message || teamError?.message);
  return { players, partnerships, weeks, teams: teams.map((team) => ({ ...team, manager_name: managerNameFor(team, managerMap) })) };
}

function partnerFor(player, partnerships, players) {
  const pairing = partnerships.find((item) => item.star_id === player.id || item.pro_id === player.id);
  if (!pairing) return null;
  const partnerId = pairing.star_id === player.id ? pairing.pro_id : pairing.star_id;
  return players.find((item) => item.id === partnerId) || null;
}

function partnerOptions(role, players, partnerships, selectedId = '') {
  if (!isPairRole(role)) return '';
  const pairedIds = new Set(partnerships.flatMap((pairing) => [pairing.star_id, pairing.pro_id]));
  return players
    .filter((person) => (person.role === oppositeRole(role) || person.id === selectedId) && (!pairedIds.has(person.id) || person.id === selectedId))
    .map((person) => `<option value="${person.id}" ${person.id === selectedId ? 'selected' : ''}>${escapeHtml(person.name)}</option>`)
    .join('');
}

async function loadRoster() {
  if (!isOwnerSurface && activeLeagueId !== defaultLeagueId) return;
  if (!$('#rosterResults')) return;
  const loadVersion = ++loadVersions.roster;
  const query = $('#rosterSearch').value.trim();
  $('#rosterResults').innerHTML = loadingMarkup('Loading cast');
  let rosterData;
  try { rosterData = await getPairingData(); } catch (error) { console.error(error); return renderLoadError($('#rosterResults'), 'load the cast', loadRoster); }
  if (loadVersion !== loadVersions.roster) return;
  const { players: allPlayers, partnerships, weeks, teams } = rosterData;
  const players = allPlayers.filter((player) => player.name.toLowerCase().includes(query.toLowerCase()) && (rosterFilter === 'all' || castCategory(player) === rosterFilter));
  if (!players.length) return showRosterMessage(canManageCast ? 'No cast members yet. Add the first one here.' : 'No cast members match this view.');
  $('#rosterResults').innerHTML = players.map((player) => `
    <div class="row cast-roster-row" data-cast-detail="${player.id}" tabindex="0" role="button" aria-label="View ${escapeHtml(player.name)} profile"><img class="player-photo" style="object-position:${player.image_position ?? 50}% center" src="${escapeHtml(displayImagePath(player))}" alt="">
      <span><b>${escapeHtml(player.name)}</b><small>${rosterDetail(player, partnerships, allPlayers, weeks, teams)}</small></span>
      ${canManageCast ? `<button data-player-id="${player.id}">Edit</button>` : '<span class="row-chevron" aria-hidden="true">›</span>'}
    </div>`).join('');
  document.querySelectorAll('[data-player-id]').forEach((button) => button.addEventListener('click', (event) => { event.stopPropagation(); editPlayer(button.dataset.playerId); }));
  document.querySelectorAll('[data-cast-detail]').forEach((row) => {
    const open = () => canManageCast ? editPlayer(row.dataset.castDetail) : openCastDetail(row.dataset.castDetail);
    row.addEventListener('click', open);
    row.addEventListener('keydown', (event) => {
      if (event.target.closest('button,input,select,textarea,a')) return;
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); }
    });
  });
}

async function openCastDetail(castMemberId, returnTeamId = null, returnAction = null) {
  if (!standingsSnapshot && !isOwnerSurface) await loadStandings();
  const [{ data: member, error: memberError }, pairingData] = await Promise.all([
    db.from('cast_members').select('*').eq('id', castMemberId).single(),
    getPairingData().catch((error) => ({ error })),
  ]);
  if (memberError || pairingData.error) {
    console.error(memberError || pairingData.error);
    return showNotice(friendlyError('load this cast member'));
  }
  const partner = partnerFor(member, pairingData.partnerships, pairingData.players);
  const team = pairingData.teams.find((item) => item.id === member.fantasy_team_id);
  const scoreEntry = standingsSnapshot ? [...standingsSnapshot.weekMemberPoints.values()].reduce((total, weekPoints) => {
    const entry = weekPoints.get(member.id);
    total.official += Number(entry?.official || 0);
    total.appearances += Number(entry?.appearances || 0);
    total.appearanceCount += Number(entry?.appearanceCount || 0);
    return total;
  }, { official: 0, appearances: 0, appearanceCount: 0 }) : { official: 0, appearances: 0, appearanceCount: 0 };
  const fantasyPoints = Number(scoreEntry.official || 0) + Number(scoreEntry.appearances || 0);
  const details = member.profile_details && typeof member.profile_details === 'object'
    ? Object.entries(member.profile_details).filter(([, value]) => value).map(([label, value]) => `<div><small>${escapeHtml(label.replaceAll('_', ' '))}</small><strong>${escapeHtml(value)}</strong></div>`).join('')
    : '';
  openModal(`${returnTeamId || returnAction ? `<button class="profile-back-button secondary" id="profileBack" type="button">← Back to ${returnAction ? 'dance' : 'team'}</button>` : ''}<div class="cast-profile-hero"><img src="${escapeHtml(displayImagePath(member))}" style="object-position:${member.image_position ?? 50}% center" alt="${escapeHtml(member.name)}"><div><p class="eyebrow">${escapeHtml(displayRole(member))}</p><h2>${escapeHtml(member.name)}</h2><p class="sub">${partner ? `Partnered with ${escapeHtml(partner.name)}` : 'Current season cast'}</p>${team ? `<span class="cast-team-pill">${escapeHtml(team.team_name || defaultTeamName(team.manager_name))}</span>` : '<span class="cast-team-pill">Available cast</span>'}</div></div>
    <div class="cast-profile-stats"><div><strong>${fantasyPoints}</strong><span>Fantasy points</span></div>${isAnyPairRole(member.role) ? `<div><strong>${Number(scoreEntry.official || 0)}</strong><span>Judges total</span></div>` : ''}<div><strong>${Number(scoreEntry.appearanceCount || 0)}</strong><span>Appearances</span></div>${canHaveMirrorballWins(member.role, member.is_hough) ? `<div><strong>${Number(member.mirrorball_wins || 0)}</strong><span>Past wins</span></div>` : ''}</div>
    <section class="cast-profile-copy"><h3>About ${escapeHtml(member.name.split(' ')[0])}</h3><p>${escapeHtml(member.bio || 'Biography details have not been added yet.')}</p>${member.career_highlights ? `<h3>Career highlights</h3><p>${escapeHtml(member.career_highlights)}</p>` : ''}</section>${details ? `<div class="cast-profile-details">${details}</div>` : ''}`);
  $('#profileBack')?.addEventListener('click', () => returnAction ? returnAction() : openTeamDetail(returnTeamId));
}

function rosterDetail(player, partnerships, players, weeks, teams) {
  const partner = partnerFor(player, partnerships, players);
  const partnership = partnerships.find((item) => item.star_id === player.id || item.pro_id === player.id);
  const base = escapeHtml(player.role === 'Surprise' && player.custom_appearance_points ? `Surprise · +${player.custom_appearance_points}` : displayRole(player));
  const fantasyTeam = teams.find((team) => team.id === player.fantasy_team_id);
  const teamText = fantasyTeam ? ` · ${escapeHtml(fantasyTeam.team_name || defaultTeamName(fantasyTeam.manager_name))}` : '';
  if (!isAnyPairRole(player.role)) return `${base}${teamText}`;
  const partnerText = partner ? `${escapeHtml(partner.name)}${teamText}` : '<strong class="missing">No partner assigned</strong>';
  if (!player.role.startsWith('Eliminated')) return `${base} · ${partnerText}`;
  const week = weeks.find((item) => item.id === player.eliminated_week_id);
  return `${base} · ${partnerText} · Eliminated ${week ? `Week ${week.number}` : 'week not set'}`;
}

async function editPlayer(id) {
  try {
    const { players, partnerships } = await getPairingData();
    const player = players.find((item) => item.id === id);
    const partner = partnerFor(player, partnerships, players);
    const partnership = partnerships.find((item) => item.star_id === player.id || item.pro_id === player.id);
    openModal(`<div class="cast-modal-heading"><img id="editPhotoPreview" class="cast-modal-photo" style="object-position:${player.image_position ?? 50}% center" src="${escapeHtml(displayImagePath(player))}" alt=""><div><p class="eyebrow">Cast Member</p><h2>${escapeHtml(player.name)}</h2><p class="sub">Update cast details, partnership, or portrait framing.</p></div></div>
      <label>Role<select id="editRole" ${player.role.startsWith('Eliminated') ? 'disabled' : ''}>${(player.role.startsWith('Eliminated') ? [player.role] : assignableRoles).map((role) => `<option ${role === player.role ? 'selected' : ''}>${role}</option>`).join('')}</select>${player.role.startsWith('Eliminated') ? '<span class="range-note">Eliminated roles are managed by completing a week.</span>' : ''}</label>
      <div id="roleDetailField" ${player.role === 'Judges + Hosts' ? '' : 'hidden'}><label>Type<select id="editRoleDetail"><option ${player.role_detail === 'Judge' ? 'selected' : ''}>Judge</option><option ${player.role_detail === 'Host' ? 'selected' : ''}>Host</option><option ${!player.role_detail || player.role_detail === 'Judge + Host' ? 'selected' : ''}>Judge + Host</option></select></label><label class="check-row"><input id="editIsHough" type="checkbox" ${player.is_hough || player.role === 'Hough' ? 'checked' : ''}> Hough scoring rate</label></div>
      <label id="surpriseRate" ${player.role === 'Surprise' ? '' : 'hidden'}>Points per appearance<input id="editRate" type="number" min="0" value="${player.custom_appearance_points ?? ''}"></label>
      <label id="partnerField" ${isAnyPairRole(player.role) ? '' : 'hidden'}>Partner<select id="editPartner"><option value="">No partner</option>${partnerOptions(activePairRole(player.role), players, partnerships, partner?.id)}</select></label>
      <label id="partnershipNameField" ${partner ? '' : 'hidden'}>Partnership name <span class="optional">(optional)</span><input id="partnershipName" value="${escapeHtml(partnership?.partnership_name || '')}" placeholder="e.g., Team Sparkle"></label>
      <label>Portrait position<input id="imagePosition" type="range" min="0" max="100" value="${player.image_position ?? 50}"><span class="range-note">Move left or right to center the image.</span></label>
      <label>Biography <span class="optional">(optional)</span><textarea id="editBio" rows="4">${escapeHtml(player.bio || '')}</textarea></label>
      <label>Career highlights <span class="optional">(optional)</span><textarea id="editCareerHighlights" rows="3">${escapeHtml(player.career_highlights || '')}</textarea></label>
      <label id="editMirrorballWinsField" ${canHaveMirrorballWins(player.role, player.is_hough) ? '' : 'hidden'}>Past Mirrorball wins<input id="editMirrorballWins" type="number" min="0" max="99" value="${Number(player.mirrorball_wins || 0)}"></label>
      <div class="modal-actions"><button id="savePlayer">Save changes</button><button id="deletePlayer" class="danger">Delete cast member</button></div>`);
    const syncEditWinsField = () => { const eligible = canHaveMirrorballWins($('#editRole').value, $('#editIsHough').checked); $('#editMirrorballWinsField').hidden = !eligible; if (!eligible) $('#editMirrorballWins').value = '0'; };
    $('#editRole').addEventListener('change', (event) => {
      const role = event.target.value;
      $('#surpriseRate').hidden = role !== 'Surprise';
      $('#roleDetailField').hidden = role !== 'Judges + Hosts';
      $('#partnerField').hidden = !isAnyPairRole(role);
      if (isAnyPairRole(role)) $('#editPartner').innerHTML = `<option value="">No partner</option>${partnerOptions(activePairRole(role), players, partnerships, partner?.id)}`;
      syncEditWinsField();
    });
    $('#editIsHough').addEventListener('change', syncEditWinsField);
    $('#editPartner').addEventListener('change', (event) => { $('#partnershipNameField').hidden = !event.target.value; });
    $('#imagePosition').addEventListener('input', (event) => { $('#editPhotoPreview').style.objectPosition = `${event.target.value}% center`; });
    $('#savePlayer').addEventListener('click', async () => {
      const saveButton = $('#savePlayer');
      if (saveButton.disabled) return;
      saveButton.disabled = true;
      const role = $('#editRole').value;
      if (role === 'Surprise' && $('#editRate').value === '') { saveButton.disabled = false; return alert('Enter the Surprise points per appearance.'); }
      const partnerId = isAnyPairRole(role) ? $('#editPartner').value : '';
      const partnershipName = $('#editPartner').value ? $('#partnershipName').value.trim() || null : null;
      const { error: saveError } = await db.rpc('save_cast_member_profile_atomic', {
        p_cast_member_id: id, p_name: player.name, p_role: role,
        p_image_path: player.image_path || storedImagePathFor(player.name), p_image_position: Number($('#imagePosition').value),
        p_custom_appearance_points: role === 'Surprise' ? Number($('#editRate').value) : null,
        p_role_detail: role === 'Judges + Hosts' ? $('#editRoleDetail').value : null,
        p_is_hough: role === 'Judges + Hosts' && $('#editIsHough').checked,
        p_partner_id: partnerId || null, p_partnership_name: partnershipName,
        p_bio: $('#editBio').value.trim() || null, p_career_highlights: $('#editCareerHighlights').value.trim() || null,
        p_mirrorball_wins: canHaveMirrorballWins(role, role === 'Judges + Hosts' && $('#editIsHough').checked) ? Number($('#editMirrorballWins').value || 0) : 0,
      });
      if (saveError) { saveButton.disabled = false; return alert(`Couldn’t save ${player.name}: ${saveError.message}`); }
      $('#modal').close(); loadRoster(); loadTeams(); loadStandings();
    });
    $('#deletePlayer').addEventListener('click', () => openConfirmation({ title: `Delete ${player.name}?`, message: 'This permanently removes the cast member and cannot be undone.', confirmLabel: 'Delete cast member', destructive: true, onCancel: () => editPlayer(id), onConfirm: async () => { const { error } = await db.rpc('delete_cast_member_atomic', { p_cast_member_id: id }); if (!error) { loadRoster(); loadTeams(); loadStandings(); } return error; } }));
  } catch (error) { alert(`Couldn’t open this cast member: ${error.message}`); }
}

async function openAddPlayer() {
  let pairingData;
  try { pairingData = await getPairingData(); } catch (error) { return alert(`Couldn’t prepare partnerships: ${error.message}`); }
  const { players, partnerships } = pairingData;
  openModal(`<h2>Add Cast Member</h2><p class="sub">Their image path is set automatically from their name.</p>
    <label>Name<input id="newName" autocomplete="off" required></label>
    <label>Role<select id="newRole">${assignableRoles.map((role) => `<option>${role}</option>`).join('')}</select></label>
    <div id="newRoleDetailField" hidden><label>Type<select id="newRoleDetail"><option>Judge</option><option>Host</option><option>Judge + Host</option></select></label><label class="check-row"><input id="newIsHough" type="checkbox"> Hough scoring rate</label></div>
    <label id="newSurpriseRate" hidden>Points per appearance<input id="newRate" type="number" min="0"></label>
    <label id="newPartnerField">Add partnership <span class="optional">(optional)</span><select id="newPartner"><option value="">No partner yet</option>${partnerOptions('Star', players, partnerships)}</select></label>
    <label>Biography <span class="optional">(optional)</span><textarea id="newBio" rows="4"></textarea></label>
    <label>Career highlights <span class="optional">(optional)</span><textarea id="newCareerHighlights" rows="3"></textarea></label>
    <label id="newMirrorballWinsField" hidden>Past Mirrorball wins<input id="newMirrorballWins" type="number" min="0" max="99" value="0"></label>
    <button id="createPlayer">Create cast member</button>`);
  const syncNewWinsField = () => { const eligible = canHaveMirrorballWins($('#newRole').value, $('#newIsHough').checked); $('#newMirrorballWinsField').hidden = !eligible; if (!eligible) $('#newMirrorballWins').value = '0'; };
  $('#newRole').addEventListener('change', (event) => {
    const role = event.target.value;
    $('#newSurpriseRate').hidden = role !== 'Surprise';
    $('#newRoleDetailField').hidden = role !== 'Judges + Hosts';
    $('#newPartnerField').hidden = !isPairRole(role);
    if (isPairRole(role)) $('#newPartner').innerHTML = `<option value="">No partner yet</option>${partnerOptions(role, players, partnerships)}`;
    syncNewWinsField();
  });
  $('#newIsHough').addEventListener('change', syncNewWinsField);
  $('#createPlayer').addEventListener('click', async () => {
    const name = $('#newName').value.trim();
    if (!name) return alert('Enter a cast member name first.');
    const role = $('#newRole').value;
    if (role === 'Surprise' && $('#newRate').value === '') return alert('Enter the Surprise points per appearance.');
    const partnerId = isPairRole(role) ? $('#newPartner').value : '';
    const createButton = $('#createPlayer');
    createButton.disabled = true;
    const { error } = await db.rpc('save_cast_member_profile_atomic', {
      p_cast_member_id: null, p_name: name, p_role: role, p_image_path: storedImagePathFor(name), p_image_position: 50,
      p_custom_appearance_points: role === 'Surprise' ? Number($('#newRate').value) : null,
      p_role_detail: role === 'Judges + Hosts' ? $('#newRoleDetail').value : null,
      p_is_hough: role === 'Judges + Hosts' && $('#newIsHough').checked,
      p_partner_id: partnerId || null, p_partnership_name: null,
      p_bio: $('#newBio').value.trim() || null, p_career_highlights: $('#newCareerHighlights').value.trim() || null,
      p_mirrorball_wins: canHaveMirrorballWins(role, role === 'Judges + Hosts' && $('#newIsHough').checked) ? Number($('#newMirrorballWins').value || 0) : 0,
    });
    if (error) { createButton.disabled = false; return alert(`Couldn’t create ${name}: ${error.message}`); }
    $('#modal').close(); loadRoster(); loadTeams(); loadStandings();
  });
}

async function loadTeams() {
  if (!$('#commissionerTeamResults')) return;
  const loadVersion = ++loadVersions.teams;
  $('#commissionerTeamResults').innerHTML = loadingMarkup('Loading fantasy teams');
  const [{ data: teams, error: teamError }, { data: castMembers, error: castError }, managerMap] = await Promise.all([
    db.from('fantasy_teams').select('*').eq('league_id', defaultLeagueId).order('manager_name'),
    db.from('cast_members').select('*').order('name'),
    getTeamManagerMap(),
  ]);
  if (loadVersion !== loadVersions.teams) return;
  if (teamError || castError) {
    console.error(teamError || castError);
    renderLoadError($('#commissionerTeamResults'), 'load fantasy teams', loadTeams);
    return;
  }
  const availableCount = castMembers.filter((member) => !member.fantasy_team_id).length;
  $('#leagueTeamCount').textContent = teams.length;
  $('#leagueCastCount').textContent = castMembers.length;
  $('#leagueAvailableCount').textContent = availableCount;
  if (!teams.length) {
    $('#commissionerTeamResults').innerHTML = '<div class="card empty">No fantasy teams yet.</div>';
    return;
  }
  $('#commissionerTeamResults').innerHTML = teams.map((team) => {
    const roster = castMembers.filter((member) => member.fantasy_team_id === team.id);
    const managerName = managerNameFor(team, managerMap);
    const displayName = team.team_name || defaultTeamName(managerName);
    const rosterPreview = roster;
    return `<article class="card team-card" data-team-card-id="${team.id}" data-team-detail="${team.id}" tabindex="0" role="button" aria-label="View ${escapeHtml(displayName)} cast roster"><div class="team-card-head"><div><p class="eyebrow">${escapeHtml(managerName)}</p><h2>${escapeHtml(displayName)}</h2></div>${canEdit ? `<button class="secondary team-edit-button" data-edit-team-id="${team.id}">Edit</button>` : '<span class="card-chevron" aria-hidden="true">›</span>'}</div>
      <p class="team-mobile-hint">Tap to view lineup</p>
      ${roster.length ? `<ul class="team-roster">${rosterPreview.map((member) => `<li><span>${escapeHtml(member.name)}</span><small>${escapeHtml(displayRole(member))}</small></li>`).join('')}</ul>` : '<p class="sub">No cast members assigned yet.</p>'}
    </article>`;
  }).join('');
  if (canEdit) {
    document.querySelectorAll('[data-team-detail]').forEach((card) => {
      card.removeAttribute('role'); card.removeAttribute('tabindex'); card.removeAttribute('aria-label');
      const editButton = card.querySelector('[data-edit-team-id]');
      editButton?.insertAdjacentHTML('beforebegin', `<button type="button" class="secondary team-view-button" data-view-team-id="${card.dataset.teamDetail}">View</button>`);
    });
  }
  document.querySelectorAll('[data-edit-team-id]').forEach((button) => button.addEventListener('click', (event) => { event.stopPropagation(); editTeamCard(button.dataset.editTeamId); }));
  document.querySelectorAll('[data-team-detail]').forEach((card) => {
    const open = () => { if (!card.classList.contains('editing')) openTeamDetail(card.dataset.teamDetail); };
    card.addEventListener('click', open);
    card.addEventListener('keydown', (event) => {
      if (event.target.closest('input,select,textarea,button,a')) return;
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); }
    });
  });
  document.querySelectorAll('[data-view-team-id]').forEach((button) => button.addEventListener('click', (event) => { event.stopPropagation(); openTeamDetail(button.dataset.viewTeamId); }));
}

async function openTeamDetail(teamId) {
  const [{ data: team, error: teamError }, { data: roster, error: rosterError }, managerMap] = await Promise.all([
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('league_id', defaultLeagueId).eq('id', teamId).single(),
    db.from('cast_members').select('*').eq('fantasy_team_id', teamId).order('name'),
    getTeamManagerMap(),
  ]);
  const error = teamError || rosterError;
  if (error) return alert(`Couldn’t load this team: ${error.message}`);
  const managerName = managerNameFor(team, managerMap);
  const displayName = team.team_name || defaultTeamName(managerName);
  openModal(`<div class="team-detail-head"><div><p class="eyebrow">${escapeHtml(managerName)}</p><h2>${escapeHtml(displayName)}</h2><p class="sub">Current roster</p></div></div>
    ${roster.length ? `<div class="team-detail-grid">${roster.map((member) => `<article class="team-detail-member" data-team-cast-detail="${member.id}" tabindex="0" role="button" aria-label="View ${escapeHtml(member.name)} profile"><img src="${escapeHtml(displayImagePath(member))}" style="object-position:${member.image_position ?? 50}% center" alt=""><div><b>${escapeHtml(member.name)}</b><span>${escapeHtml(displayRole(member))}</span></div><i aria-hidden="true">›</i></article>`).join('')}</div>` : '<p class="sub">No cast members assigned yet.</p>'}`);
  document.querySelectorAll('[data-team-cast-detail]').forEach((tile) => {
    const open = () => openCastDetail(tile.dataset.teamCastDetail, teamId);
    tile.addEventListener('click', open);
    tile.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

async function editTeamCard(teamId) {
  const [{ data: team, error: teamError }, { data: roster, error: rosterError }, managerMap] = await Promise.all([
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('league_id', defaultLeagueId).eq('id', teamId).single(),
    db.from('cast_members').select('*').eq('fantasy_team_id', teamId).order('name'),
    getTeamManagerMap(),
  ]);
  const error = teamError || rosterError;
  if (error) return alert(`Couldn’t edit this team: ${error.message}`);
  const card = document.querySelector(`[data-team-card-id="${teamId}"]`);
  if (!card) return;
  const manager = managerMap.get(teamId);
  card.classList.add('editing');
  card.innerHTML = `<div class="team-card-head"><div class="team-edit-fields"><label>Manager display name<input id="teamManagerDisplay-${teamId}" maxlength="80" value="${escapeHtml(manager?.display_name || team.manager_name || '')}" ${manager ? '' : 'disabled'}></label><label>Team name <span class="optional">(optional)</span><input id="teamName-${teamId}" value="${escapeHtml(team.team_name || '')}"></label></div></div><div class="team-edit-buttons"><button class="secondary" data-cancel-team-id="${teamId}">Cancel</button><button data-save-team-id="${teamId}">Save</button></div></div>
    ${!manager ? '<p class="sub compact-note">Connect an account to this team before editing its manager name.</p>' : ''}${roster.length ? `<ul class="team-roster">${roster.map((member) => `<li><span>${escapeHtml(member.name)}</span><small>${escapeHtml(displayRole(member))}</small></li>`).join('')}</ul>` : '<p class="sub">No cast members assigned yet.</p>'}`;
  document.querySelector(`[data-cancel-team-id="${teamId}"]`).addEventListener('click', loadTeams);
  document.querySelector(`[data-save-team-id="${teamId}"]`).addEventListener('click', async () => {
    const saveButton = document.querySelector(`[data-save-team-id="${teamId}"]`);
    if (saveButton.disabled) return;
    saveButton.disabled = true;
    const team_name = $(`#teamName-${teamId}`).value.trim();
    const displayName = $(`#teamManagerDisplay-${teamId}`).value.trim();
    if (manager && !displayName) { saveButton.disabled = false; return alert('Enter a manager display name.'); }
    const { error: saveError } = await db.rpc('update_team_profile_from_profile', { p_team_id: teamId, p_team_name: team_name || null, p_manager_user_id: manager?.user_id || null, p_display_name: manager ? displayName : null });
    if (saveError) { saveButton.disabled = false; return alert(`Couldn’t save this team: ${saveError.message}`); }
    loadTeams(); loadStandings();
  });
}

function weekTitle(week) {
  return week.title || (week.theme ? `${week.theme} Week` : `Week ${week.number}`);
}

function formatAirDate(value) {
  if (!value) return '';
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return '';
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(parsed);
}

function weekAiringLabel(week, fallback = '') {
  const dates = [formatAirDate(week.air_date), formatAirDate(week.second_air_date)].filter(Boolean);
  return dates.join(' + ') || fallback;
}

async function loadLeagueSettings() {
  if (!$('#leagueName')) return;
  const loadVersion = ++loadVersions.settings;
  const { data, error } = await db.from('league_settings').select('league_name').eq('id', 1).maybeSingle();
  if (loadVersion !== loadVersions.settings) return;
  $('#leagueName').textContent = error ? 'DWTS Fantasy League' : data?.league_name || 'DWTS Fantasy League';
  $('#editLeagueName').hidden = !canEdit;
  $('#editLeagueName').onclick = canEdit ? () => {
    openModal(`<p class="eyebrow">League settings</p><h2>Edit league name</h2><label>League name<input id="leagueNameInput" maxlength="80" value="${escapeHtml($('#leagueName').textContent)}"></label><div class="modal-actions"><button id="saveLeagueName">Save name</button></div>`);
    $('#saveLeagueName').addEventListener('click', async () => {
      const saveButton = $('#saveLeagueName');
      if (saveButton.disabled) return;
      saveButton.disabled = true;
      const name = $('#leagueNameInput').value.trim();
      if (!name) { saveButton.disabled = false; return alert('Enter a league name.'); }
      const { error: saveError } = await db.rpc('update_league_name', { p_league_name: name });
      if (saveError) { saveButton.disabled = false; return alert(`Couldn’t save the league name: ${saveError.message}`); }
      $('#modal').close(); loadLeagueSettings();
    });
  } : null;
}

function teamPageWeeks(weeks) {
  const latestCompleted = [...weeks].reverse().find((week) => week.is_complete);
  const maximumNumber = latestCompleted ? latestCompleted.number + 1 : weeks[0]?.number;
  return maximumNumber == null ? [] : weeks.filter((week) => week.number <= maximumNumber);
}

function roleForWeek(member, week, weeks) {
  if (!member?.role?.startsWith('Eliminated')) return member?.role || '';
  const eliminatedWeek = weeks.find((item) => item.id === member.eliminated_week_id);
  if (week && eliminatedWeek && week.number <= eliminatedWeek.number) return member.role.replace('Eliminated ', '');
  return member.role;
}

function appearanceValue(member, roleMap, week, weeks, snapshot = null) {
  if (!member) return 0;
  if (member.is_hough) return Number(roleMap.get('Hough')?.appearance_points) || 0;
  const role = snapshot?.cast_role || roleForWeek(member, week, weeks);
  if (role === 'Surprise') return Number(member.custom_appearance_points) || 0;
  return Number(roleMap.get(role)?.appearance_points) || 0;
}

async function loadStandings() {
  if (!$('#standingsContent')) return;
  const loadVersion = ++loadVersions.standings;
  $('#standingsContent').innerHTML = loadingMarkup('Loading standings');
  if ($('#publicTeamResults')) $('#publicTeamResults').innerHTML = loadingMarkup('Loading your team');
  const [teamsResult, membersResult, rolesResult, partnershipsResult, weeksResult, dancesResult, scoresResult, appearancesResult] = await Promise.all([
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('league_id', defaultLeagueId).order('manager_name'),
    db.from('cast_members').select('*').order('name'),
    db.from('roles').select('name,appearance_points'),
    db.from('partnerships').select('id,star_id,pro_id').eq('active', true),
    db.from('weeks').select('*').order('number'),
    db.from('dances').select('id,kind,partnership_id,week_id'),
    db.from('dance_judge_scores').select('dance_id,score'),
    db.from('dance_appearances').select('id,dance_id,cast_member_id'),
  ]);
  if (loadVersion !== loadVersions.standings) return;
  const error = [teamsResult, membersResult, rolesResult, partnershipsResult, weeksResult, dancesResult, scoresResult, appearancesResult].find((result) => result.error)?.error;
  if (error) {
    console.error(error);
    renderLoadError($('#standingsContent'), 'load standings', loadStandings);
    $('#overviewTeamDetail').innerHTML = '';
    renderLoadError($('#publicTeamResults'), 'load your team', loadStandings);
    return;
  }
  // The completion migration adds roster snapshots. Until it has been run, do
  // not query a table that does not exist—current standings remain usable.
  let rosterSnapshots = [];
  if (weeksResult.data.some((week) => Object.prototype.hasOwnProperty.call(week, 'is_complete'))) {
    const snapshotColumns = weeksResult.data.some((week) => Object.prototype.hasOwnProperty.call(week, 'uses_rate_snapshots')) ? 'week_id,cast_member_id,fantasy_team_id,cast_member_name,cast_role,appearance_points' : 'week_id,cast_member_id,fantasy_team_id,cast_member_name,cast_role';
    const { data, error: snapshotError } = await db.from('weekly_roster_snapshots').select(snapshotColumns).eq('league_id', defaultLeagueId);
    if (loadVersion !== loadVersions.standings) return;
    if (snapshotError) {
      console.error(snapshotError);
      renderLoadError($('#standingsContent'), 'load historical standings', loadStandings);
      $('#overviewTeamDetail').innerHTML = '';
      renderLoadError($('#publicTeamResults'), 'load team history', loadStandings);
      return;
    }
    rosterSnapshots = data;
  }
  const managerMap = await getTeamManagerMap();
  if (loadVersion !== loadVersions.standings) return;
  const displayTeams = teamsResult.data.map((team) => ({ ...team, manager_name: managerNameFor(team, managerMap) }));
  const data = { teams: displayTeams, members: membersResult.data, roles: rolesResult.data, partnerships: partnershipsResult.data, weeks: weeksResult.data, dances: dancesResult.data, scores: scoresResult.data, appearances: appearancesResult.data, rosterSnapshots };
  const { teams, members, weeks, memberPoints, weekMemberPoints } = calculateLeaguePoints(data);
  const snapshotTeamByWeekMember = new Map(rosterSnapshots.map((snapshot) => [`${snapshot.week_id}:${snapshot.cast_member_id}`, snapshot.fantasy_team_id]));
  const snapshotByWeekMember = new Map(rosterSnapshots.map((snapshot) => [`${snapshot.week_id}:${snapshot.cast_member_id}`, snapshot]));
  const teamForMemberInWeek = (member, week) => snapshotTeamByWeekMember.get(`${week.id}:${member.id}`) ?? member.fantasy_team_id;
  const teamMemberPoints = new Map(teams.map((team) => [team.id, new Map()]));
  weeks.forEach((week) => {
    (weekMemberPoints.get(week.id) || new Map()).forEach((entry, memberId) => {
      const member = members.find((item) => item.id === memberId);
      const teamId = member && teamForMemberInWeek(member, week);
      if (!teamId || !teamMemberPoints.has(teamId)) return;
      const byMember = teamMemberPoints.get(teamId);
      byMember.set(memberId, (byMember.get(memberId) || 0) + entry.official + entry.appearances);
    });
  });
  standingsSnapshot = { ...data, memberPoints, weekMemberPoints, snapshotTeamByWeekMember, snapshotByWeekMember, teamForMemberInWeek, teamMemberPoints };
  const teamRows = teams.map((team) => {
    const roster = members.filter((member) => member.fantasy_team_id === team.id);
    const total = [...(teamMemberPoints.get(team.id)?.values() || [])].reduce((sum, points) => sum + points, 0);
    return { team, roster, total };
  }).sort((a, b) => b.total - a.total || (a.team.team_name || a.team.manager_name).localeCompare(b.team.team_name || b.team.manager_name));
  const latestWeek = [...weeksResult.data].reverse().find((week) => week.is_complete);
  $('#standingsSubtitle').textContent = latestWeek ? `Through ${weekTitle(latestWeek)} · current fantasy-team totals` : 'Current fantasy-team totals.';
  if (!teamRows.length) {
    $('#standingsContent').innerHTML = '<div class="card empty">No fantasy teams yet.</div>';
    $('#overviewTeamDetail').innerHTML = '';
    $('#publicTeamResults').innerHTML = '<div class="card empty">No fantasy teams yet.</div>';
    return;
  }
  const leaderTotal = teamRows[0].total;
  const isFirstPlaceTie = teamRows.filter((row) => row.total === leaderTotal).length > 1;
  if (!teamRows.some((row) => row.team.id === selectedOverviewTeamId)) selectedOverviewTeamId = teamRows[0].team.id;
  if (managerTeamId && teamRows.some((row) => row.team.id === managerTeamId)) selectedPublicTeamId = managerTeamId;
  else if (!teamRows.some((row) => row.team.id === selectedPublicTeamId)) selectedPublicTeamId = teamRows[0].team.id;
  $('#standingsContent').innerHTML = `<div class="standings-grid">${teamRows.map((row, index) => {
    const contributors = members.filter((member) => (teamMemberPoints.get(row.team.id)?.get(member.id) || 0) > 0 || member.fantasy_team_id === row.team.id).sort((a, b) => (teamMemberPoints.get(row.team.id)?.get(b.id) || 0) - (teamMemberPoints.get(row.team.id)?.get(a.id) || 0) || a.name.localeCompare(b.name));
    const tiedLeader = isFirstPlaceTie && row.total === leaderTotal;
    const rank = teamRows.findIndex((item) => item.total === row.total) + 1;
    const displayName = row.team.team_name || defaultTeamName(row.team.manager_name);
    return `<article class="card standing-card ${tiedLeader || index === 0 ? 'leader' : ''} ${tiedLeader ? 'tied-leader' : ''} ${row.team.id === selectedOverviewTeamId ? 'selected' : ''}" data-standing-team="${row.team.id}" tabindex="0" role="button" aria-label="View ${escapeHtml(displayName)} score breakdown"><div class="standing-rank">${rank}</div><div class="standing-main"><p class="eyebrow">${escapeHtml(row.team.manager_name)}</p><h2>${escapeHtml(displayName)}</h2>${tiedLeader ? '<p class="tie-note">Tied for first</p>' : ''}<div class="standing-contributors">${contributors.slice(0, 4).map((member) => `<span>${escapeHtml(member.name)} <b>${teamMemberPoints.get(row.team.id)?.get(member.id) || 0}</b></span>`).join('') || '<span>No cast assigned</span>'}${contributors.length > 4 ? `<span>+${contributors.length - 4} more</span>` : ''}</div></div><div class="standing-total"><strong>${row.total}</strong><span>points</span></div><span class="card-chevron standing-chevron" aria-hidden="true">›</span></article>`;
  }).join('')}</div>`;
  document.querySelectorAll('[data-standing-team]').forEach((card) => {
    const open = () => {
      selectedOverviewTeamId = card.dataset.standingTeam;
      document.querySelectorAll('[data-standing-team]').forEach((item) => item.classList.toggle('selected', item === card));
      if (overviewUsesSplitLayout()) renderOverviewTeamDetail();
      else openOverviewTeamDetail();
    };
    card.addEventListener('click', open);
    card.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
  standingsSnapshot.teamRows = teamRows;
  renderOverviewTeamDetail();
  renderPublicTeams();
  renderLeagueHighlights();
}

function teamScoreBreakdown(teamId, weekId = 'all') {
  const { members, weeks, roles: roleRows, weekMemberPoints, teamForMemberInWeek, snapshotByWeekMember } = standingsSnapshot;
  const roleRates = new Map(roleRows.map((role) => [role.name, Number(role.appearance_points) || 0]));
  const selectedWeeks = weekId === 'all' ? weeks : weeks.filter((week) => week.id === weekId);
  const rows = members.filter((member) => selectedWeeks.some((week) => teamForMemberInWeek(member, week) === teamId)).map((member) => {
    const sources = selectedWeeks.reduce((result, week) => {
      if (teamForMemberInWeek(member, week) !== teamId) return result;
      const entry = weekMemberPoints.get(week.id)?.get(member.id);
      result.official += entry?.official || 0;
      result.appearances += entry?.appearances || 0;
      result.appearanceCount += entry?.appearanceCount || 0;
      result.appearanceRates.push(...(entry?.appearanceRates || []));
      return result;
    }, { official: 0, appearances: 0, appearanceCount: 0, appearanceRates: [] });
    const snapshot = selectedWeeks.length === 1 ? snapshotByWeekMember.get(`${selectedWeeks[0].id}:${member.id}`) : null;
    const role = selectedWeeks.length === 1 ? snapshot?.cast_role || roleForWeek(member, selectedWeeks[0], weeks) : member.role;
    const appearanceRate = member.is_hough ? roleRates.get('Hough') || 0 : role === 'Surprise' ? Number(member.custom_appearance_points) || 0 : roleRates.get(role) || 0;
    return { member, role, appearanceRate, ...sources, total: sources.official + sources.appearances };
  }).sort((a, b) => b.total - a.total || a.member.name.localeCompare(b.member.name));
  return { rows, total: rows.reduce((sum, row) => sum + row.total, 0) };
}

function scoreBreakdownMarkup(rows, limit = null, withImages = false, includeHistoricalJudgeScores = false) {
  const visible = limit ? rows.slice(0, limit) : rows;
  return `<div class="league-score-list">${visible.map((row) => { const hasJudgeScores = row.role === 'Star' || row.role === 'Pro' || (includeHistoricalJudgeScores && ['Eliminated Star', 'Eliminated Pro'].includes(row.role)); return `<div class="league-score-row ${withImages ? 'with-photo' : ''}" data-score-cast-detail="${row.member.id}" tabindex="0" role="button">${withImages ? `<img class="score-member-photo" src="${escapeHtml(displayImagePath(row.member))}" style="object-position:${row.member.image_position ?? 50}% center" alt="">` : ''}<div class="league-score-member"><strong>${escapeHtml(row.member.name)}</strong><span class="role-rate-pill">${escapeHtml(displayRole({ ...row.member, role: row.role }))} <b>+${row.appearanceRate}</b></span></div><div class="league-score-parts">${hasJudgeScores ? `<span>Judges Total <b>${row.official}</b></span>` : ''}<span class="appearance-part">Appearances <b>${row.appearances}</b></span></div><strong class="league-score-total">${row.total}</strong></div>`; }).join('') || '<p class="sub league-empty">No points recorded in this view.</p>'}</div>`;
}

function bindScoreCastDetails(container = document) {
  container.querySelectorAll('[data-score-cast-detail]').forEach((row) => {
    const open = () => openCastDetail(row.dataset.scoreCastDetail);
    row.addEventListener('click', open);
    row.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

function overviewTeamDetailMarkup(row) {
  const breakdown = teamScoreBreakdown(row.team.id);
  const displayName = row.team.team_name || defaultTeamName(row.team.manager_name);
  return `<div class="league-detail-head"><div><p class="eyebrow">Selected team</p><h2>${escapeHtml(displayName)}</h2><p class="sub">Managed by ${escapeHtml(row.team.manager_name)}</p></div><div class="league-detail-total"><strong>${breakdown.total}</strong><span>season points</span></div></div><p class="top-cast-label">Top Five Cast Members</p>${scoreBreakdownMarkup(breakdown.rows, 5, false, true)}`;
}

function overviewUsesSplitLayout() {
  return ($('#standings')?.classList.contains('active') && $('.overview-layout')?.getBoundingClientRect().width >= 1030);
}

function renderOverviewTeamDetail() {
  if (!standingsSnapshot) return;
  if (!overviewUsesSplitLayout()) {
    $('#overviewTeamDetail').innerHTML = '';
    return;
  }
  const row = standingsSnapshot.teamRows?.find((item) => item.team.id === selectedOverviewTeamId);
  if (!row) return;
  $('#overviewTeamDetail').innerHTML = `<section class="card overview-team-detail">${overviewTeamDetailMarkup(row)}</section>`;
  bindScoreCastDetails($('#overviewTeamDetail'));
}

function openOverviewTeamDetail() {
  const row = standingsSnapshot?.teamRows?.find((item) => item.team.id === selectedOverviewTeamId);
  if (row) { openModal(`<div class="overview-mobile-detail">${overviewTeamDetailMarkup(row)}</div>`); bindScoreCastDetails($('#modalBody')); }
}

function renderLeagueHighlights() {
  const { weeks, teams, members, weekMemberPoints, teamForMemberInWeek } = standingsSnapshot;
  const week = [...weeks].reverse().find((item) => item.is_complete);
  if (!week) {
    $('#highlightWeek').textContent = 'Waiting for results';
    return;
  }
  const points = weekMemberPoints.get(week.id) || new Map();
  const teamTotals = teams.map((team) => ({
    team,
    total: [...points].reduce((sum, [memberId, entry]) => {
      const member = members.find((item) => item.id === memberId);
      return sum + (member && teamForMemberInWeek(member, week) === team.id ? entry.official + entry.appearances : 0);
    }, 0),
  }));
  const bestTeamScore = Math.max(0, ...teamTotals.map((item) => item.total));
  const winningTeams = bestTeamScore > 0 ? teamTotals.filter((item) => item.total === bestTeamScore) : [];
  const castRows = members.map((member) => {
    const entry = points.get(member.id) || { official: 0, appearances: 0, appearanceCount: 0 };
    return { member, total: entry.official + entry.appearances, appearances: entry.appearanceCount || 0 };
  });
  const bestCastScore = Math.max(0, ...castRows.map((item) => item.total));
  const castMVPs = bestCastScore > 0 ? castRows.filter((item) => item.total === bestCastScore) : [];
  const mostAppearances = Math.max(0, ...castRows.map((item) => item.appearances));
  const appearanceLeaders = castRows.filter((item) => item.appearances === mostAppearances && mostAppearances > 0);
  const highlightDetails = new Map();
  const compactNames = (items, getName, key) => {
    if (!items.length) return '';
    const visible = items.slice(0, 3).map((item) => `<span>${escapeHtml(getName(item))}</span>`).join('');
    const remaining = items.length - 3;
    highlightDetails.set(key, items.map(getName));
    return `<div class="highlight-name-list">${visible}${remaining > 0 ? `<button type="button" class="highlight-more" data-highlight-detail="${key}">+${remaining} more tied</button>` : ''}</div>`;
  };
  const teamNames = compactNames(winningTeams, ({ team }) => team.team_name || defaultTeamName(team.manager_name), 'teams');
  const mvpNames = compactNames(castMVPs, ({ member }) => member.name, 'cast');
  const appearanceNames = compactNames(appearanceLeaders, ({ member }) => member.name, 'appearances');
  $('#highlightWeek').textContent = weekTitle(week);
  $('#leagueHighlightCards').innerHTML = `<article class="card"><small>Team of the week</small>${bestTeamScore ? `<strong class="highlight-value">${bestTeamScore}</strong><p>fantasy points${winningTeams.length > 1 ? ' each' : ''}</p>${teamNames}` : '<p>No fantasy-team points were recorded.</p>'}</article><article class="card"><small>Top cast score</small>${bestCastScore ? `<strong class="highlight-value">${bestCastScore}</strong><p>points${castMVPs.length > 1 ? ' each' : ''}</p>${mvpNames}` : '<p>No cast points were recorded.</p>'}</article><article class="card"><small>Most appearances</small>${mostAppearances ? `<strong class="highlight-value">${mostAppearances}</strong><p>dance${mostAppearances === 1 ? '' : 's'}${appearanceLeaders.length > 1 ? ' each' : ''}</p>${appearanceNames}` : '<p>No appearances were recorded.</p>'}</article>`;
  document.querySelectorAll('[data-highlight-detail]').forEach((button) => button.addEventListener('click', () => {
    const names = highlightDetails.get(button.dataset.highlightDetail) || [];
    openModal(`<p class="eyebrow">${escapeHtml(weekTitle(week))}</p><h2>Tied leaders</h2><div class="highlight-detail-list">${names.map((name) => `<span>${escapeHtml(name)}</span>`).join('')}</div>`);
  }));
}

function renderPublicTeams() {
  if (!standingsSnapshot) return;
  const { teamRows, members, weeks, weekMemberPoints, teamForMemberInWeek } = standingsSnapshot;
  const visibleTeamRows = managerTeamId ? teamRows.filter((row) => row.team.id === managerTeamId) : teamRows;
  const selected = visibleTeamRows?.find((row) => row.team.id === selectedPublicTeamId) || visibleTeamRows?.[0];
  if (!selected) {
    $('#editMyTeam').hidden = true;
    return $('#publicTeamResults').innerHTML = '<div class="card empty">This account is not connected to a fantasy team yet.</div>';
  }
  selectedPublicTeamId = selected.team.id;
  const visibleWeeks = teamPageWeeks(weeks);
  if (selectedPublicWeekId !== 'all' && !visibleWeeks.some((week) => week.id === selectedPublicWeekId)) selectedPublicWeekId = 'all';
  const displayName = selected.team.team_name || defaultTeamName(selected.team.manager_name);
  $('#myTeamTitle').textContent = selected.team.team_name || 'My Team';
  $('#myTeamEyebrow').textContent = `${managerFirstName || selected.team.manager_name.split(' ')[0]}'s Manager View`;
  const roster = members.filter((member) => member.fantasy_team_id === selected.team.id).sort((a, b) => a.name.localeCompare(b.name));
  const available = members.filter((member) => !member.fantasy_team_id).sort((a, b) => a.name.localeCompare(b.name));
  const canEditThisTeam = Boolean(managerTeamId && selected.team.id === managerTeamId);
  const breakdown = teamScoreBreakdown(selected.team.id, selectedPublicWeekId);
  const weekHistory = visibleWeeks.map((week) => {
    const total = [...(weekMemberPoints.get(week.id) || new Map())].reduce((sum, [memberId, entry]) => {
      const member = members.find((item) => item.id === memberId);
      return sum + (member && teamForMemberInWeek(member, week) === selected.team.id ? entry.official + entry.appearances : 0);
    }, 0);
    const summary = week.is_complete ? total : weekAiringLabel(week, 'TBA');
    return `<button class="${selectedPublicWeekId === week.id ? 'selected' : ''}" data-public-week="${week.id}" aria-pressed="${selectedPublicWeekId === week.id}"><span>Week ${week.number}</span><strong class="${week.is_complete ? '' : 'air-date'}">${escapeHtml(summary)}</strong></button>`;
  }).join('');
  const peopleMarkup = (people) => people.map((member) => `<article class="league-cast-person available-cast-person"><button type="button" class="available-profile-button" data-available-cast-detail="${member.id}" aria-label="View ${escapeHtml(member.name)} profile"><img src="${escapeHtml(displayImagePath(member))}" style="object-position:${member.image_position ?? 50}% center" alt=""><span><strong>${escapeHtml(member.name)}</strong><small>${escapeHtml(displayRole(member))}</small></span></button>${canEditThisTeam ? `<button type="button" class="claim-cast-button" data-claim-cast="${member.id}">Claim</button>` : ''}</article>`).join('');
  const switcher = visibleTeamRows.length > 1 ? `<div class="team-switcher" aria-label="Choose a fantasy team">${visibleTeamRows.map((row) => `<button class="${row.team.id === selected.team.id ? 'selected' : ''}" data-public-team="${row.team.id}"><span>${escapeHtml(row.team.team_name || defaultTeamName(row.team.manager_name))}</span><small>${row.total} pts</small></button>`).join('')}</div>` : '';
  $('#editMyTeam').hidden = !canEditThisTeam;
  $('#editMyTeam').onclick = canEditThisTeam ? () => openMyTeamEditor(selected.team) : null;
  $('#publicTeamResults').innerHTML = `${switcher}<section class="card public-team-detail"><div class="team-summary-strip"><div class="team-history-strip">${weekHistory || '<p class="sub">Weekly history will appear after scoring begins.</p>'}</div><div class="league-detail-total"><strong>${breakdown.total}</strong><span>${selectedPublicWeekId === 'all' ? 'season' : 'week'} points</span></div></div><div class="public-team-columns"><section><div class="public-section-head"><div><p class="eyebrow">Scoring</p><h3>Team Roster</h3></div></div>${scoreBreakdownMarkup(breakdown.rows, null, true, selectedPublicWeekId === 'all')}</section><div class="team-side-column"><section class="available-cast-panel"><div class="public-section-head"><div><p class="eyebrow">Free agents</p><h3>Available Cast</h3></div><span>${available.length} available</span></div><p class="sub">Cast members not currently assigned to a fantasy team.</p><div class="league-cast-grid available-grid">${peopleMarkup(available) || '<div class="empty compact-empty">Every cast member is currently assigned.</div>'}</div></section><section id="tradeCenter" class="trade-center card"><div class="trade-center-loading">Loading trades…</div></section></div></div></section>`;
  document.querySelectorAll('[data-public-team]').forEach((button) => button.addEventListener('click', () => { selectedPublicTeamId = button.dataset.publicTeam; selectedPublicWeekId = 'all'; renderPublicTeams(); }));
  document.querySelectorAll('[data-public-week]').forEach((button) => button.addEventListener('click', () => { selectedPublicWeekId = selectedPublicWeekId === button.dataset.publicWeek ? 'all' : button.dataset.publicWeek; renderPublicTeams(); }));
  bindScoreCastDetails($('#publicTeamResults'));
  document.querySelectorAll('[data-claim-cast]').forEach((button) => button.addEventListener('click', (event) => {
    event.stopPropagation();
    openClaimCastMember(button.dataset.claimCast);
  }));
  document.querySelectorAll('[data-available-cast-detail]').forEach((tile) => {
    tile.addEventListener('click', () => openCastDetail(tile.dataset.availableCastDetail));
  });
  loadTrades();
}

function openClaimCastMember(incomingId) {
  const incoming = standingsSnapshot?.members.find((member) => member.id === incomingId && !member.fantasy_team_id);
  const team = standingsSnapshot?.teamRows.find((row) => row.team.id === managerTeamId)?.team;
  const roster = standingsSnapshot?.members.filter((member) => member.fantasy_team_id === managerTeamId).sort((a, b) => a.name.localeCompare(b.name)) || [];
  if (!incoming || !team || !roster.length) return alert('This cast member is no longer available for a roster swap.');
  const teamName = team.team_name || defaultTeamName(team.manager_name);
  openModal(`<p class="eyebrow">Free-agent claim</p><h2>Claim ${escapeHtml(incoming.name)}</h2><p class="sub">Choose one member of ${escapeHtml(teamName)} to release. The swap happens immediately and keeps every roster the same size.</p><div class="claim-cast-hero"><img src="${escapeHtml(displayImagePath(incoming))}" style="object-position:${incoming.image_position ?? 50}% center" alt=""><div><small>You receive</small><strong>${escapeHtml(incoming.name)}</strong><span>${escapeHtml(displayRole(incoming))}</span></div></div><p class="eyebrow claim-release-heading">Choose who to release</p><div class="trade-picker-grid claim-release-grid">${roster.map((member) => tradeMemberChoice(member, false, `data-claim-release="${member.id}"`)).join('')}</div><button id="confirmCastClaim" disabled>Claim</button>`);
  let outgoingId = null;
  document.querySelectorAll('[data-claim-release]').forEach((button) => button.addEventListener('click', () => {
    outgoingId = button.dataset.claimRelease;
    document.querySelectorAll('[data-claim-release]').forEach((choice) => choice.classList.toggle('selected', choice === button));
    $('#confirmCastClaim').disabled = false;
  }));
  $('#confirmCastClaim').addEventListener('click', async () => {
    if (!outgoingId) return;
    const claimButton = $('#confirmCastClaim');
    claimButton.disabled = true;
    claimButton.textContent = 'Claiming…';
    const { error } = await db.rpc('swap_available_cast_member_into_team', { p_team_id: managerTeamId, p_incoming_cast_member_id: incoming.id, p_outgoing_cast_member_id: outgoingId });
    if (error) {
      claimButton.disabled = false;
      claimButton.textContent = 'Claim';
      return alert(`Couldn’t claim ${incoming.name}: ${error.message}`);
    }
    $('#modal').close();
    loadStandings();
  });
}

function tradeContext(trade) {
  const { members, teamRows } = standingsSnapshot;
  const teamById = new Map(teamRows.map((row) => [row.team.id, row.team]));
  const memberById = new Map(members.map((member) => [member.id, member]));
  const initiatorTeam = teamById.get(trade.initiator_team_id);
  const counterpartyTeam = teamById.get(trade.counterparty_team_id);
  return {
    initiatorTeam,
    counterpartyTeam,
    initiatorMember: memberById.get(trade.initiator_cast_member_id),
    counterpartyMember: memberById.get(trade.counterparty_cast_member_id),
    initiatorTeamName: initiatorTeam?.team_name || defaultTeamName(initiatorTeam?.manager_name),
    counterpartyTeamName: counterpartyTeam?.team_name || defaultTeamName(counterpartyTeam?.manager_name),
  };
}

function tradeMemberChoice(member, selected = false, attribute = '') {
  return `<button type="button" class="trade-member-choice ${selected ? 'selected' : ''}" ${attribute}><img src="${escapeHtml(displayImagePath(member))}" style="object-position:${member?.image_position ?? 50}% center" alt=""><span><b>${escapeHtml(member?.name || 'Unavailable')}</b><small>${escapeHtml(displayRole(member))}</small></span></button>`;
}

function tradeSwapMarkup(mine, theirs, options = {}) {
  const selectableSides = new Set(options.selectableSides || []);
  const side = (member, label, sideName) => {
    const changed = options.changedSide === sideName;
    const selectable = !options.changedSide && selectableSides.has(sideName);
    const tag = selectable ? 'button' : 'div';
    const attributes = selectable ? `type="button" data-counter-side="${sideName}" aria-label="Replace ${escapeHtml(member?.name || 'this cast member')} in the counter offer"` : '';
    return `<${tag} ${attributes} class="trade-swap-person ${changed ? 'changed' : ''} ${selectable ? 'selectable' : ''}"><img src="${escapeHtml(displayImagePath(member))}" style="object-position:${member?.image_position ?? 50}% center" alt=""><span><small>${escapeHtml(label)}</small><b>${escapeHtml(member?.name || 'Unavailable')}</b></span>${changed ? '<button type="button" class="trade-remove-change" aria-label="Remove this change">×</button>' : ''}</${tag}>`;
  };
  return `<div class="trade-swap">${side(mine, 'You send', 'mine')}<i aria-hidden="true">⇄</i>${side(theirs, 'You receive', 'theirs')}</div>`;
}

function tradeTimeRemaining(expiresAt) {
  const milliseconds = new Date(expiresAt).getTime() - Date.now();
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) return 'Expired';
  const minutes = Math.ceil(milliseconds / 60000);
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m left`;
  return `${minutes}m left`;
}

function refreshTradeCountdowns() {
  let hasExpired = false;
  document.querySelectorAll('[data-trade-expires]').forEach((item) => {
    const label = tradeTimeRemaining(item.dataset.tradeExpires);
    item.textContent = label;
    if (label === 'Expired') hasExpired = true;
  });
  if (hasExpired) loadTrades();
}

function historyTradeContext(entry) {
  const memberById = new Map((standingsSnapshot?.members || []).map((member) => [member.id, member]));
  return {
    initiatorMember: memberById.get(entry.initiator_cast_member_id) || { name: entry.initiator_cast_member_name },
    counterpartyMember: memberById.get(entry.counterparty_cast_member_id) || { name: entry.counterparty_cast_member_name },
  };
}

function openTradeConfirmation({ trade, title, message, confirmLabel, destructive = false, onConfirm }) {
  const context = tradeContext(trade);
  const isInitiator = trade.initiator_team_id === managerTeamId;
  const mine = isInitiator ? context.initiatorMember : context.counterpartyMember;
  const theirs = isInitiator ? context.counterpartyMember : context.initiatorMember;
  openModal(`<div class="trade-confirm"><p class="eyebrow">Confirm trade</p><h2>${escapeHtml(title)}</h2><p class="sub">${escapeHtml(message)}</p><div class="confirm-trade-preview">${tradeSwapMarkup(mine, theirs)}</div><p id="tradeConfirmError" class="sub error" hidden></p><div class="modal-actions"><button id="cancelTradeConfirmation" type="button" class="secondary">Cancel</button><button id="confirmTradeAction" type="button" class="${destructive ? 'danger' : ''}">${escapeHtml(confirmLabel)}</button></div></div>`);
  $('#cancelTradeConfirmation').addEventListener('click', () => $('#modal').close());
  $('#confirmTradeAction').addEventListener('click', async () => {
    const button = $('#confirmTradeAction');
    button.disabled = true;
    const error = await onConfirm();
    if (error) {
      button.disabled = false;
      const errorBox = $('#tradeConfirmError');
      errorBox.hidden = false;
      errorBox.textContent = friendlyError('complete this trade action');
      console.error(error);
      return;
    }
    $('#modal').close();
  });
}

async function loadTrades() {
  const loadVersion = ++tradeLoadVersion;
  const container = $('#tradeCenter');
  if (!container) return;
  if (tradeCountdownTimer) clearInterval(tradeCountdownTimer);
  if (!managerTeamId) {
    container.innerHTML = '<div class="trade-center-head"><div><p class="eyebrow">Manager tools</p><h3>Trades</h3></div></div><p class="sub">Connect a manager account to a fantasy team to trade.</p>';
    return;
  }
  const [offersResult, historyResult, notificationsResult] = await Promise.all([
    db.rpc('get_my_trade_offers'),
    db.rpc('get_my_trade_history'),
    db.rpc('get_my_trade_result_notifications'),
  ]);
  if (loadVersion !== tradeLoadVersion || !container.isConnected) return;
  if (offersResult.error || historyResult.error || notificationsResult.error) {
    const error = offersResult.error || historyResult.error || notificationsResult.error;
    const setupMissing = ['42P01', 'PGRST202'].includes(error.code) || /trade|function/i.test(error.message || '');
    console.error(error);
    container.innerHTML = `<div class="trade-center-head"><div><p class="eyebrow">Manager tools</p><h3>Trades</h3></div></div><p class="sub ${setupMissing ? '' : 'error'}">${setupMissing ? 'Run the latest trade database update to enable timers and history.' : friendlyError('load trades')}</p>${setupMissing ? '' : '<button type="button" class="secondary" id="retryTrades">Try again</button>'}`;
    $('#retryTrades')?.addEventListener('click', loadTrades);
    return;
  }
  const trades = offersResult.data || [];
  const history = historyResult.data || [];
  const notifications = notificationsResult.data || [];
  const tradeCards = (trades || []).map((trade) => {
    const context = tradeContext(trade);
    const isInitiator = trade.initiator_team_id === managerTeamId;
    const mine = isInitiator ? context.initiatorMember : context.counterpartyMember;
    const theirs = isInitiator ? context.counterpartyMember : context.initiatorMember;
    const otherTeamName = isInitiator ? context.counterpartyTeamName : context.initiatorTeamName;
    const awaitingMe = trade.awaiting_team_id === managerTeamId;
    const canCancel = !awaitingMe;
    const mayCounter = awaitingMe && trade.status === 'pending' && trade.counterparty_team_id === managerTeamId;
    return `<article class="trade-offer ${awaitingMe ? 'needs-action' : ''}"><div class="trade-offer-top"><span>${trade.status === 'countered' ? 'Counter offer' : 'Trade offer'}</span><small>${awaitingMe ? 'Your response' : `Waiting for ${escapeHtml(otherTeamName)}`}</small></div>${tradeSwapMarkup(mine, theirs)}<div class="trade-expiry"><span data-trade-expires="${escapeHtml(trade.expires_at)}">${escapeHtml(tradeTimeRemaining(trade.expires_at))}</span><small>Offer closes automatically</small></div>${awaitingMe ? `<div class="trade-actions"><button data-accept-trade="${trade.id}">Accept</button>${mayCounter ? `<button class="secondary" data-counter-trade="${trade.id}">Counter</button>` : ''}<button class="secondary trade-deny" data-deny-trade="${trade.id}">Deny</button></div>` : canCancel ? `<div class="trade-actions"><button class="secondary trade-deny" data-cancel-trade="${trade.id}">Cancel offer</button></div>` : ''}</article>`;
  }).join('');
  const statusLabels = { countered: 'Countered', accepted: 'Accepted', denied: 'Denied', expired: 'Expired', cancelled: 'Cancelled', invalidated: 'Superseded' };
  const resultCards = notifications.map((entry) => {
    const context = historyTradeContext(entry);
    const isInitiator = entry.initiator_team_id === managerTeamId;
    const mine = isInitiator ? context.initiatorMember : context.counterpartyMember;
    const theirs = isInitiator ? context.counterpartyMember : context.initiatorMember;
    const accepted = entry.event_type === 'accepted';
    return `<article class="trade-offer trade-result ${accepted ? 'accepted' : 'denied'}"><div class="trade-offer-top"><span>Trade ${accepted ? 'accepted' : 'denied'}</span><small>New result</small></div><p class="trade-result-message">${accepted ? 'Your offer was accepted and the cast members switched teams.' : 'The other manager denied your offer.'}</p>${tradeSwapMarkup(mine, theirs)}<div class="trade-actions"><button type="button" class="secondary" data-dismiss-trade-result="${entry.id}">Dismiss</button></div></article>`;
  }).join('');
  const historyCards = history.map((entry) => {
    const context = historyTradeContext(entry);
    const isInitiator = entry.initiator_team_id === managerTeamId;
    const mine = isInitiator ? context.initiatorMember : context.counterpartyMember;
    const theirs = isInitiator ? context.counterpartyMember : context.initiatorMember;
    const date = new Date(entry.event_at).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
    return `<article class="trade-history-item"><div class="trade-history-head"><span class="trade-status trade-status-${entry.event_type}">${statusLabels[entry.event_type] || entry.event_type}</span><small>${escapeHtml(date)}</small></div>${tradeSwapMarkup(mine, theirs)}</article>`;
  }).join('');
  const activeCards = `${resultCards}${tradeCards}`;
  container.innerHTML = `<div class="trade-center-head"><div><p class="eyebrow">Manager tools</p><h3>Trades</h3></div><button id="newTrade" class="secondary">Propose trade</button></div><p class="sub">Swap one cast member with another manager.</p><div class="trade-view-tabs" role="tablist" aria-label="Trade activity"><button type="button" role="tab" aria-selected="${tradeViewMode === 'active'}" data-trade-view="active" class="${tradeViewMode === 'active' ? 'selected' : ''}">Active <span>${trades.length + notifications.length}</span></button><button type="button" role="tab" aria-selected="${tradeViewMode === 'history'}" data-trade-view="history" class="${tradeViewMode === 'history' ? 'selected' : ''}">History</button></div><div class="trade-list" role="tabpanel" ${tradeViewMode === 'active' ? '' : 'hidden'}>${activeCards || '<div class="trade-empty">No active trade offers or new results.</div>'}</div><div class="trade-history-list" role="tabpanel" ${tradeViewMode === 'history' ? '' : 'hidden'}>${historyCards || '<div class="trade-empty">No past trade activity yet.</div>'}</div>`;
  $('#newTrade')?.addEventListener('click', openNewTrade);
  document.querySelectorAll('[data-trade-view]').forEach((button) => button.addEventListener('click', () => { tradeViewMode = button.dataset.tradeView; loadTrades(); }));
  document.querySelectorAll('[data-accept-trade]').forEach((button) => button.addEventListener('click', async () => {
    const trade = trades.find((item) => item.id === button.dataset.acceptTrade);
    openTradeConfirmation({ trade, title: 'Accept this trade?', message: 'The cast members will switch teams immediately and the change will be captured in the next completed week.', confirmLabel: 'Accept trade', onConfirm: async () => {
      tradeLoadVersion += 1;
      const { error } = await db.rpc('accept_trade', { p_trade_id: trade.id });
      if (!error) await loadStandings();
      await loadTrades();
      return error;
    } });
  }));
  document.querySelectorAll('[data-counter-trade]').forEach((button) => button.addEventListener('click', () => openCounterTrade(trades.find((trade) => trade.id === button.dataset.counterTrade))));
  document.querySelectorAll('[data-deny-trade]').forEach((button) => button.addEventListener('click', async () => {
    const trade = trades.find((item) => item.id === button.dataset.denyTrade);
    openTradeConfirmation({ trade, title: 'Deny this trade?', message: 'This offer will close and move to your trade history.', confirmLabel: 'Deny trade', destructive: true, onConfirm: async () => {
      tradeLoadVersion += 1;
      const { error } = await db.rpc('deny_trade', { p_trade_id: trade.id });
      await loadTrades();
      return error;
    } });
  }));
  document.querySelectorAll('[data-cancel-trade]').forEach((button) => button.addEventListener('click', () => {
    const trade = trades.find((item) => item.id === button.dataset.cancelTrade);
    openTradeConfirmation({ trade, title: 'Cancel this offer?', message: 'The other manager will no longer be able to respond. The cancelled offer will remain in trade history.', confirmLabel: 'Cancel offer', destructive: true, onConfirm: async () => {
      tradeLoadVersion += 1;
      const { error } = await db.rpc('cancel_trade', { p_trade_id: trade.id });
      await loadTrades();
      return error;
    } });
  }));
  document.querySelectorAll('[data-dismiss-trade-result]').forEach((button) => button.addEventListener('click', async () => {
    button.disabled = true;
    button.textContent = 'Dismissing…';
    tradeLoadVersion += 1;
    const { error } = await db.rpc('dismiss_trade_result', { p_history_id: button.dataset.dismissTradeResult });
    await loadTrades();
    if (error) {
      console.error(error);
      showNotice(friendlyError('dismiss this trade result'));
    }
  }));
  refreshTradeCountdowns();
  tradeCountdownTimer = setInterval(() => document.hidden ? refreshTradeCountdowns() : loadTrades(), 60000);
}

function openNewTrade() {
  const { members, teamRows } = standingsSnapshot;
  const myRoster = members.filter((member) => member.fantasy_team_id === managerTeamId).sort((a, b) => a.name.localeCompare(b.name));
  const otherRoster = members.filter((member) => member.fantasy_team_id && member.fantasy_team_id !== managerTeamId);
  if (!myRoster.length || !otherRoster.length) return alert('Both teams need an assigned cast member before proposing a trade.');
  renderNewTrade({ mineId: null, teamId: null, theirsId: null });

  function renderNewTrade(state) {
    const otherTeams = teamRows.filter((row) => row.team.id !== managerTeamId && members.some((member) => member.fantasy_team_id === row.team.id));
    const theirRoster = state.teamId ? members.filter((member) => member.fantasy_team_id === state.teamId).sort((a, b) => a.name.localeCompare(b.name)) : [];
    openModal(`<p class="eyebrow">New trade</p><h2>Propose a Trade</h2><p class="sub">Build a one-for-one offer. The other manager has 48 hours to respond.</p><div class="trade-builder"><section><div class="trade-builder-title"><span>1</span><div><b>Choose who you send</b><small>Your current roster</small></div></div><div class="trade-picker-grid">${myRoster.map((member) => tradeMemberChoice(member, state.mineId === member.id, `data-trade-mine="${member.id}"`)).join('')}</div></section><section><div class="trade-builder-title"><span>2</span><div><b>Choose a manager</b><small>Select the team you want to trade with</small></div></div><div class="trade-team-picker">${otherTeams.map(({ team }) => `<button type="button" class="trade-team-choice ${state.teamId === team.id ? 'selected' : ''}" data-trade-team="${team.id}"><span><b>${escapeHtml(team.team_name || defaultTeamName(team.manager_name))}</b><small>${escapeHtml(team.manager_name)}</small></span></button>`).join('')}</div></section>${state.teamId ? `<section><div class="trade-builder-title"><span>3</span><div><b>Choose who you request</b><small>${escapeHtml(teamRows.find((row) => row.team.id === state.teamId)?.team.team_name || 'Their roster')}</small></div></div><div class="trade-picker-grid">${theirRoster.map((member) => tradeMemberChoice(member, state.theirsId === member.id, `data-trade-theirs="${member.id}"`)).join('')}</div></section>` : ''}</div><p id="tradeBuilderError" class="sub error" hidden></p><div class="modal-actions"><button id="sendTrade" ${state.mineId && state.theirsId ? '' : 'disabled'}>Send Trade</button></div>`);
    document.querySelectorAll('[data-trade-mine]').forEach((button) => button.addEventListener('click', () => renderNewTrade({ ...state, mineId: button.dataset.tradeMine })));
    document.querySelectorAll('[data-trade-team]').forEach((button) => button.addEventListener('click', () => renderNewTrade({ ...state, teamId: button.dataset.tradeTeam, theirsId: null })));
    document.querySelectorAll('[data-trade-theirs]').forEach((button) => button.addEventListener('click', () => renderNewTrade({ ...state, theirsId: button.dataset.tradeTheirs })));
    $('#sendTrade').addEventListener('click', async () => {
      const button = $('#sendTrade'); button.disabled = true;
      tradeLoadVersion += 1;
      const { error } = await db.rpc('request_trade', { p_my_cast_member_id: state.mineId, p_requested_cast_member_id: state.theirsId });
      if (error) {
        await loadTrades();
        button.disabled = false;
        console.error(error);
        const errorBox = $('#tradeBuilderError'); errorBox.hidden = false; errorBox.textContent = friendlyError('send this trade');
        return;
      }
      $('#modal').close();
      await loadTrades();
    });
  }
}

function openCounterTrade(trade) {
  if (!trade || !standingsSnapshot) return;
  const { members } = standingsSnapshot;
  const context = tradeContext(trade);
  const initiatorAlternatives = members.filter((member) => member.fantasy_team_id === trade.initiator_team_id && member.id !== trade.initiator_cast_member_id).sort((a, b) => a.name.localeCompare(b.name));
  const counterpartyAlternatives = members.filter((member) => member.fantasy_team_id === trade.counterparty_team_id && member.id !== trade.counterparty_cast_member_id).sort((a, b) => a.name.localeCompare(b.name));
  if (!initiatorAlternatives.length && !counterpartyAlternatives.length) return alert('There are no other cast members available for a counter offer.');
  renderCounter({ choosing: null, changedSide: null, replacementId: null });

  function renderCounter(state) {
    const replacement = members.find((member) => member.id === state.replacementId);
    const mine = state.changedSide === 'mine' ? replacement : context.counterpartyMember;
    const theirs = state.changedSide === 'theirs' ? replacement : context.initiatorMember;
    const choices = state.choosing === 'mine' ? counterpartyAlternatives : state.choosing === 'theirs' ? initiatorAlternatives : [];
    const selectableSides = [
      ...(counterpartyAlternatives.length ? ['mine'] : []),
      ...(initiatorAlternatives.length ? ['theirs'] : []),
    ];
    const currentSwap = tradeSwapMarkup(mine, theirs, { changedSide: state.changedSide, selectableSides });
    openModal(`<p class="eyebrow">Trade response</p><h2>Counter Offer</h2><p class="sub">Select the cast member in the current offer that you want to replace. Once selected, remove that change with × before choosing the other side.</p><div class="counter-swap-card">${currentSwap}</div>${state.choosing ? `<div class="counter-picker"><div class="trade-builder-title"><span>1</span><div><b>${state.choosing === 'mine' ? 'Choose a new cast member to send' : `Choose another member of ${escapeHtml(context.initiatorTeamName)}`}</b><small>Only this side of the offer will change</small></div></div><div class="trade-picker-grid">${choices.map((member) => tradeMemberChoice(member, false, `data-counter-member="${member.id}"`)).join('')}</div></div>` : ''}<p id="counterTradeError" class="sub error" hidden></p><div class="modal-actions"><button id="sendCounterTrade" ${state.changedSide ? '' : 'disabled'}>Send counter</button></div>`);
    document.querySelectorAll('[data-counter-side]').forEach((button) => button.addEventListener('click', () => renderCounter({ choosing: button.dataset.counterSide, changedSide: null, replacementId: null })));
    document.querySelectorAll('[data-counter-member]').forEach((button) => button.addEventListener('click', () => renderCounter({ choosing: null, changedSide: state.choosing, replacementId: button.dataset.counterMember })));
    $('.trade-remove-change')?.addEventListener('click', () => renderCounter({ choosing: null, changedSide: null, replacementId: null }));
    $('#sendCounterTrade').addEventListener('click', async () => {
      const initiatorId = state.changedSide === 'theirs' ? state.replacementId : trade.initiator_cast_member_id;
      const counterpartyId = state.changedSide === 'mine' ? state.replacementId : trade.counterparty_cast_member_id;
      const button = $('#sendCounterTrade'); button.disabled = true;
      tradeLoadVersion += 1;
      const { error } = await db.rpc('counter_trade', { p_trade_id: trade.id, p_initiator_cast_member_id: initiatorId, p_counterparty_cast_member_id: counterpartyId });
      if (error) {
        await loadTrades();
        button.disabled = false;
        console.error(error);
        const errorBox = $('#counterTradeError'); errorBox.hidden = false; errorBox.textContent = friendlyError('send this counter offer');
        return;
      }
      $('#modal').close();
      await loadTrades();
    });
  }
}

function openMyTeamEditor(team) {
  const replacing = managerNavLabelMode !== 'default';
  const selectedMode = managerNavLabelMode === 'custom' ? 'custom' : 'team';
  openModal(`<p class="eyebrow">Manager settings</p><h2>Edit My Team</h2><p class="sub">Update your display name, fantasy team name, and how this page appears in navigation.</p><label>Display name<input id="myDisplayName" maxlength="80" value="${escapeHtml(managerDisplayName || [managerFirstName, managerLastName].filter(Boolean).join(' '))}" autocomplete="name"></label><label>Team name <span class="optional">(optional)</span><input id="myTeamName" value="${escapeHtml(team.team_name || '')}"></label><label class="check-row"><input id="replaceMyTeamLabel" type="checkbox" ${replacing ? 'checked' : ''}> Replace “My Team” in the navigation</label><div id="myTeamLabelOptions" class="nav-label-options" ${replacing ? '' : 'hidden'}><label>Use<select id="myTeamLabelMode"><option value="team" ${selectedMode === 'team' ? 'selected' : ''}>Team name</option><option value="custom" ${selectedMode === 'custom' ? 'selected' : ''}>Custom label</option></select></label><label id="customTeamLabelField" ${selectedMode === 'custom' ? '' : 'hidden'}>Custom label<input id="customTeamLabel" maxlength="24" value="${escapeHtml(managerCustomNavLabel)}" placeholder="e.g., Freddy’s Team"></label></div><div class="modal-actions"><button id="saveMyTeamProfile">Save changes</button></div>`);
  const syncOptions = () => {
    $('#myTeamLabelOptions').hidden = !$('#replaceMyTeamLabel').checked;
    $('#customTeamLabelField').hidden = $('#myTeamLabelMode').value !== 'custom';
  };
  $('#replaceMyTeamLabel').addEventListener('change', syncOptions);
  $('#myTeamLabelMode').addEventListener('change', syncOptions);
  $('#saveMyTeamProfile').addEventListener('click', async () => {
    const displayName = $('#myDisplayName').value.trim();
    const teamName = $('#myTeamName').value.trim();
    const navMode = $('#replaceMyTeamLabel').checked ? $('#myTeamLabelMode').value : 'default';
    const customLabel = navMode === 'custom' ? $('#customTeamLabel').value.trim() : null;
    if (!displayName) return alert('Enter your display name.');
    if (navMode === 'team' && !teamName) return alert('Add a team name before using it in the navigation.');
    if (navMode === 'custom' && !customLabel) return alert('Enter a custom navigation label.');
    const saveButton = $('#saveMyTeamProfile');
    saveButton.disabled = true;
    const { error } = await db.rpc('update_my_team_settings', { p_display_name: displayName, p_team_name: teamName || null, p_nav_label_mode: navMode, p_custom_nav_label: customLabel });
    if (error) { saveButton.disabled = false; return alert(`Couldn’t save your team profile: ${error.message}`); }
    managerDisplayName = displayName;
    managerFirstName = displayName.split(/\s+/)[0] || '';
    managerLastName = displayName.split(/\s+/).slice(1).join(' ');
    managerTeamName = teamName; managerNavLabelMode = navMode; managerCustomNavLabel = customLabel || '';
    $('#auth').textContent = managerFirstName || displayName;
    const teamNavLabel = navMode === 'custom' ? customLabel : navMode === 'team' ? teamName : 'My Team';
    $('#myTeamNav .nav-label').textContent = teamNavLabel;
    $('#myTeamNav').setAttribute('aria-label', teamNavLabel);
    $('#modal').close(); loadTeams(); loadStandings();
  });
}

function calculateLeaguePoints(data) {
  const memberById = new Map(data.members.map((member) => [member.id, member]));
  const roleMap = new Map(data.roles.map((role) => [role.name, role]));
  const partnershipById = new Map(data.partnerships.map((partnership) => [partnership.id, partnership]));
  const danceById = new Map(data.dances.map((dance) => [dance.id, dance]));
  const weekById = new Map(data.weeks.map((week) => [week.id, week]));
  const snapshotByWeekMember = new Map((data.rosterSnapshots || []).map((snapshot) => [`${snapshot.week_id}:${snapshot.cast_member_id}`, snapshot]));
  const scoresByDance = new Map();
  const memberPoints = new Map(data.members.map((member) => [member.id, 0]));
  const weekMemberPoints = new Map();
  const add = (memberId, weekId, kind, points) => {
    if (!memberById.has(memberId)) return;
    memberPoints.set(memberId, (memberPoints.get(memberId) || 0) + points);
    if (!weekMemberPoints.has(weekId)) weekMemberPoints.set(weekId, new Map());
    const memberWeek = weekMemberPoints.get(weekId);
    const record = memberWeek.get(memberId) || { official: 0, appearances: 0, appearanceCount: 0, appearanceRates: [] };
    record[kind] += points;
    if (kind === 'appearances') { record.appearanceCount += 1; record.appearanceRates.push(points); }
    memberWeek.set(memberId, record);
  };
  data.scores.forEach((score) => scoresByDance.set(score.dance_id, (scoresByDance.get(score.dance_id) || 0) + score.score));
  data.dances.filter((dance) => dance.kind === 'competitive').forEach((dance) => {
    const pairing = partnershipById.get(dance.partnership_id);
    const score = scoresByDance.get(dance.id) || 0;
    if (pairing) [pairing.star_id, pairing.pro_id].forEach((id) => add(id, dance.week_id, 'official', score));
  });
  data.appearances.forEach((appearance) => {
    const dance = danceById.get(appearance.dance_id);
    const member = memberById.get(appearance.cast_member_id);
    if (dance) add(member?.id, dance.week_id, 'appearances', appearanceValue(member, roleMap, weekById.get(dance.week_id), data.weeks, snapshotByWeekMember.get(`${dance.week_id}:${member?.id}`)));
  });
  return { teams: data.teams, members: data.members, weeks: data.weeks, memberPoints, weekMemberPoints };
}

async function loadScoreDesk() {
  const loadVersion = ++scoreDeskLoadVersion;
  if ($('#scoreDeskContent')) $('#scoreDeskContent').innerHTML = loadingMarkup('Loading dances');
  const { data: weeks, error } = await db.from('weeks').select('*').order('number');
  if (loadVersion !== scoreDeskLoadVersion) return;
  if (error) { console.error(error); return renderLoadError($('#scoreDeskContent'), 'load weeks', loadScoreDesk); }
  const visibleWeeks = isScoreDeskSurface ? weeks : teamPageWeeks(weeks);
  if (isScoreDeskSurface && $('#newWeek')) $('#newWeek').hidden = !canManageShow || Boolean(weeks[weeks.length - 1]?.is_season_finale);
  if (!visibleWeeks.length) {
    $('#weekTabs').innerHTML = '';
    $('#scoreDeskContent').innerHTML = '<div class="card empty">No weeks yet. Add Week 1 when you are ready to score.</div>';
    return;
  }
  if (!visibleWeeks.some((week) => week.id === selectedWeekId)) selectedWeekId = visibleWeeks[visibleWeeks.length - 1].id;
  $('#weekTabs').setAttribute('role', 'tablist');
  $('#weekTabs').setAttribute('aria-label', 'Choose a week');
  $('#weekTabs').innerHTML = visibleWeeks.map((week) => `<button role="tab" aria-selected="${week.id === selectedWeekId}" class="${week.id === selectedWeekId ? 'selected' : ''}" data-score-week="${week.id}">Week ${week.number}</button>`).join('');
  document.querySelectorAll('[data-score-week]').forEach((button) => button.addEventListener('click', () => { selectedWeekId = button.dataset.scoreWeek; editingWeekId = null; loadScoreDesk(); }));
  const week = visibleWeeks.find((item) => item.id === selectedWeekId);
  const { data: dances, error: danceError } = await db.from('dances').select('id,kind,partnership_id,name,dance_type,song,sort_order').eq('week_id', week.id).order('sort_order');
  if (loadVersion !== scoreDeskLoadVersion) return;
  if (danceError) { console.error(danceError); return renderLoadError($('#scoreDeskContent'), 'load dances', loadScoreDesk); }
  const danceIds = dances.map((dance) => dance.id);
  const [{ data: judgeScores, error: judgeError }, { data: appearances, error: appearanceError }] = danceIds.length ? await Promise.all([
    db.from('dance_judge_scores').select('dance_id,judge_name,score').in('dance_id', danceIds),
    db.from('dance_appearances').select('id,dance_id,cast_member_id').in('dance_id', danceIds),
  ]) : [{ data: [], error: null }, { data: [], error: null }];
  if (loadVersion !== scoreDeskLoadVersion) return;
  if (judgeError || appearanceError) { console.error(judgeError || appearanceError); return renderLoadError($('#scoreDeskContent'), 'load dance scoring', loadScoreDesk); }
  const [pairResult, roleResult, snapshotResult] = await Promise.all([
    getPairingData().then((data) => ({ data })).catch((error) => ({ error })),
    db.from('roles').select('name,appearance_points'),
    week.is_complete ? db.from('weekly_roster_snapshots').select('*').eq('league_id', defaultLeagueId).eq('week_id', week.id) : Promise.resolve({ data: [], error: null }),
  ]);
  if (loadVersion !== scoreDeskLoadVersion) return;
  const detailError = pairResult.error || roleResult.error || snapshotResult.error;
  if (detailError) {
    console.error(detailError);
    renderLoadError($('#scoreDeskContent'), week.is_complete ? 'load this week’s historical details' : 'load dance details', loadScoreDesk);
    return;
  }
  const pairData = pairResult.data;
  const danceDetailContext = { roles: roleResult.data || [], snapshots: snapshotResult.data || [] };
  const judgeOrder = ['Carrie Ann', 'Derek', 'Bruno', ...(week.guest_judge_name ? [week.guest_judge_name] : [])];
  const scoresForDance = (danceId) => judgeScores.filter((score) => score.dance_id === danceId).sort((a, b) => judgeOrder.indexOf(a.judge_name) - judgeOrder.indexOf(b.judge_name));
  const labelForDance = (dance, index) => {
    if (dance.kind === 'performance') return dance.name || `Week ${week.number} Dance ${index + 1}`;
    const pairing = pairData.partnerships.find((item) => item.id === dance.partnership_id);
    const star = pairData.players.find((player) => player.id === pairing?.star_id);
    const pro = pairData.players.find((player) => player.id === pairing?.pro_id);
    return star && pro ? `${star.name} & ${pro.name}` : `Competitive Dance ${index + 1}`;
  };
  const dancers = (danceId) => appearances.filter((appearance) => appearance.dance_id === danceId).map((appearance) => pairData.players.find((player) => player.id === appearance.cast_member_id)).filter(Boolean);
  const appearanceSummary = (danceId) => { const cast = dancers(danceId); if (!cast.length) return ''; const shown = cast.slice(0, 3); return `<div class="dance-cast" title="${escapeHtml(cast.map((member) => member.name).join(', '))}"><span>Cast</span>${shown.map((member) => `<b>${escapeHtml(member.name)}</b>`).join('')}${cast.length > shown.length ? `<b>+${cast.length - shown.length}</b>` : ''}</div>`; };
  const competitiveCount = dances.filter((dance) => dance.kind === 'competitive').length;
  const performanceCount = dances.length - competitiveCount;
  const supportsCompletion = Object.prototype.hasOwnProperty.call(week, 'is_complete');
  if (supportsCompletion !== supportsDatabaseHardening) {
    supportsDatabaseHardening = supportsCompletion;
    if (!isScoreDeskSurface) loadRules();
  }
  const airing = weekAiringLabel(week);
  const completionStatus = week.is_complete ? 'Week complete' : !isScoreDeskSurface ? 'Upcoming week' : week.is_finale ? 'No elimination · ready to complete' : `${week.double_elimination ? 'Double elimination' : 'Standard elimination'} · elimination not set`;
  const weekStatus = [airing, week.is_season_finale ? 'Season finale' : '', completionStatus].filter(Boolean).join(' · ');
  const editable = canManageShow && !week.is_complete;
  const weekEditing = editable && editingWeekId === week.id;
  if (!editable) editingWeekId = null;
  const weekFields = `<div class="week-inline-fields"><label>Theme <span class="optional">(optional)</span><input id="weekTheme" value="${escapeHtml(week.theme || '')}"></label><label>Week title <span class="optional">(optional)</span><input id="weekTitle" value="${escapeHtml(week.title || '')}" placeholder="Optional custom title"></label><label>Air date <span class="optional">(optional)</span><input id="weekAirDate" type="date" value="${escapeHtml(week.air_date || '')}"></label><label class="check-label"><input id="twoNightAiring" type="checkbox" ${week.second_air_date ? 'checked' : ''}> Two-night airing</label><label id="secondAirDateField" ${week.second_air_date ? '' : 'hidden'}>Second night date<input id="weekSecondAirDate" type="date" value="${escapeHtml(week.second_air_date || '')}"></label><label class="check-label"><input id="guestJudgeEnabled" type="checkbox" ${week.guest_judge_name ? 'checked' : ''}> Guest judge</label><label id="guestJudgeField" ${week.guest_judge_name ? '' : 'hidden'}>Guest judge name<input id="guestJudgeName" value="${escapeHtml(week.guest_judge_name || '')}"></label><label class="check-label"><input id="doubleElimination" type="checkbox" ${week.double_elimination ? 'checked' : ''} ${week.is_finale ? 'disabled' : ''}> Double elimination</label><label class="check-label"><input id="isFinale" type="checkbox" ${week.is_finale ? 'checked' : ''}> No elimination</label><label class="check-label"><input id="isSeasonFinale" type="checkbox" ${week.is_season_finale ? 'checked' : ''}> Season finale</label></div>`;
  $('#scoreDeskContent').innerHTML = `<div class="score-week-head card ${weekEditing ? 'week-editing' : ''}"><div class="week-heading"><p class="eyebrow">Week ${week.number}</p><div class="week-title-line"><h2>${escapeHtml(weekTitle(week))}</h2>${editable && !weekEditing ? '<button class="week-edit-pill" id="editWeek">Edit</button>' : ''}</div>${weekEditing ? weekFields : `<p class="sub">${week.guest_judge_name ? `Guest judge: ${escapeHtml(week.guest_judge_name)} · ` : ''}${weekStatus}</p>`}</div>${weekEditing ? '<div class="week-edit-actions"><button class="secondary" id="cancelWeekEdit">Cancel</button><button id="saveWeek">Save changes</button></div>' : `<div class="week-summary"><span>${competitiveCount} competitive</span><span>${performanceCount} performances</span>${week.is_complete ? '<span class="week-complete">Complete</span>' : ''}</div><div class="score-week-actions">${week.is_complete && canManageShow ? '<button class="secondary" id="weekLedger">Week ledger</button>' : ''}${editable ? `<button id="newDance">Add Dance</button>${supportsCompletion ? '<button class="secondary" id="completeWeek">Mark Complete</button>' : ''}` : ''}</div>`}</div>
    ${weekEditing ? '<p class="reorder-hint">Drag the handles to match the show order, then save the week. Arrow keys also move a focused handle.</p>' : ''}<div class="dance-list ${weekEditing ? 'reorder-mode' : ''}">${dances.length ? dances.map((dance, index) => { const scores = scoresForDance(dance.id); const details = [dance.dance_type, dance.song].filter(Boolean).map(escapeHtml); const title = escapeHtml(labelForDance(dance, index)); const scoreStatus = dance.kind === 'competitive' && scores.length < 3 + (week.guest_judge_name ? 1 : 0) ? `<span class="dance-score-pending">${scores.length ? `${scores.length} judge scores entered` : 'Awaiting scores'}</span>` : ''; return `<article class="card dance-row dance-${dance.kind}" ${weekEditing ? `data-reorder-id="${dance.id}"` : `data-dance-detail="${dance.id}" tabindex="0" role="button" aria-label="View details for ${title}"`}><div class="dance-card-top">${weekEditing ? `<button type="button" class="dance-drag-handle" aria-label="Move ${title}" title="Drag to reorder">☰</button>` : ''}<div class="dance-card-info"><p class="eyebrow">${dance.kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h3>${title}</h3>${weekEditing ? `<p class="reorder-detail">${escapeHtml([dance.dance_type, dance.song].filter(Boolean).join(' · '))}${scoreStatus}</p>` : ''}</div>${editable ? `<button class="secondary" data-edit-dance="${dance.id}">Edit</button>` : !weekEditing ? '<span class="card-chevron" aria-hidden="true">›</span>' : ''}</div>${!weekEditing && dance.kind === 'competitive' ? `<div class="dance-details"><span>${details[0] || 'Dance type not set'}</span>${details[1] ? `<span>${details[1]}</span>` : ''}</div><div class="judge-paddles" aria-label="Judge scores">${scores.map((score) => `<img src="${judgeScoreImage(score.score)}" alt="${escapeHtml(score.judge_name)}: ${score.score}">`).join('')}${scoreStatus}</div>` : ''}${weekEditing ? '' : appearanceSummary(dance.id)}</article>`; }).join('') : '<div class="card empty">No dances entered for this week.</div>'}</div>`;
  if (!week.is_complete && !isScoreDeskSurface) {
    document.querySelectorAll('#scoreDeskContent .dance-score-pending').forEach((item) => item.remove());
    document.querySelectorAll('#scoreDeskContent .week-summary span').forEach((item) => { if (item.textContent === '0 performances') item.remove(); });
    const summary = $('#scoreDeskContent .week-summary');
    if (summary) summary.insertAdjacentHTML('beforeend', '<span class="week-upcoming">Upcoming</span>');
  }
  if (editable && !weekEditing) {
    document.querySelectorAll('#scoreDeskContent [data-dance-detail]').forEach((tile) => {
      tile.removeAttribute('role'); tile.removeAttribute('tabindex'); tile.removeAttribute('aria-label');
      tile.querySelector('[data-edit-dance]')?.insertAdjacentHTML('beforebegin', `<button type="button" class="secondary" data-view-dance="${tile.dataset.danceDetail}">View</button>`);
    });
  }
  $('#newDance')?.addEventListener('click', () => openNewDance(week, dances.length));
  $('#editWeek')?.addEventListener('click', () => { editingWeekId = week.id; loadScoreDesk(); });
  $('#cancelWeekEdit')?.addEventListener('click', () => { editingWeekId = null; loadScoreDesk(); });
  $('#twoNightAiring')?.addEventListener('change', (event) => { $('#secondAirDateField').hidden = !event.target.checked; if (!event.target.checked) $('#weekSecondAirDate').value = ''; });
  $('#guestJudgeEnabled')?.addEventListener('change', (event) => { $('#guestJudgeField').hidden = !event.target.checked; });
  $('#isFinale')?.addEventListener('change', (event) => { $('#doubleElimination').disabled = event.target.checked; if (event.target.checked) $('#doubleElimination').checked = false; });
  $('#saveWeek')?.addEventListener('click', (event) => withBusy(event.currentTarget, 'Saving…', () => saveInlineWeek(week, dances)));
  if (weekEditing) attachDanceReorder();
  $('#completeWeek')?.addEventListener('click', () => openCompleteWeek(week));
  $('#weekLedger')?.addEventListener('click', () => openWeekLedger(week));
  document.querySelectorAll('[data-edit-dance]').forEach((button) => {
    const dance = dances.find((item) => item.id === button.dataset.editDance);
    button.addEventListener('click', (event) => { event.stopPropagation(); openEditDance(week, dance, dances.indexOf(dance)); });
  });
  document.querySelectorAll('[data-dance-detail]').forEach((tile) => {
    const dance = dances.find((item) => item.id === tile.dataset.danceDetail);
    const open = () => openDanceDetail(week, dance, dances.indexOf(dance), pairData, scoresForDance(dance.id), dancers(dance.id), danceDetailContext);
    tile.addEventListener('click', open);
    tile.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
  document.querySelectorAll('[data-view-dance]').forEach((button) => button.addEventListener('click', (event) => { event.stopPropagation(); document.querySelector(`[data-dance-detail="${button.dataset.viewDance}"]`)?.click(); }));
}

function openDanceDetail(week, dance, index, pairData, scores, cast, context = {}) {
  const title = dance.kind === 'competitive' ? (() => { const pairing = pairData.partnerships.find((item) => item.id === dance.partnership_id); const star = pairData.players.find((player) => player.id === pairing?.star_id); const pro = pairData.players.find((player) => player.id === pairing?.pro_id); return star && pro ? `${star.name} & ${pro.name}` : `Competitive Dance ${index + 1}`; })() : dance.name || `Week ${week.number} Dance ${index + 1}`;
  const pairing = pairData.partnerships.find((item) => item.id === dance.partnership_id);
  const star = pairData.players.find((player) => player.id === pairing?.star_id);
  const pro = pairData.players.find((player) => player.id === pairing?.pro_id);
  const roleAtWeek = (member) => roleForWeek(member, week, pairData.weeks || [week]);
  const roleMap = new Map((context.roles || []).map((role) => [role.name, role]));
  const snapshotMap = new Map((context.snapshots || []).map((snapshot) => [snapshot.cast_member_id, snapshot]));
  const teamMap = new Map((pairData.teams || []).map((team) => [team.id, team]));
  const scoreTotal = scores.reduce((sum, score) => sum + Number(score.score || 0), 0);
  const contributions = new Map();
  const addContribution = (member, points) => { if (member) contributions.set(member.id, (contributions.get(member.id) || 0) + points); };
  if (dance.kind === 'competitive') { addContribution(star, scoreTotal); addContribution(pro, scoreTotal); }
  cast.forEach((member) => addContribution(member, appearanceValue(member, roleMap, week, pairData.weeks || [week], snapshotMap.get(member.id))));
  const allCast = [...new Map([star, pro, ...cast].filter(Boolean).map((member) => [member.id, member])).values()];
  const detailRows = allCast.map((member) => {
    const snapshot = snapshotMap.get(member.id);
    const teamId = snapshot?.fantasy_team_id ?? member.fantasy_team_id;
    const team = teamMap.get(teamId);
    const teamName = snapshot?.team_name || team?.team_name || (snapshot?.manager_name ? defaultTeamName(snapshot.manager_name) : team?.manager_name ? defaultTeamName(team.manager_name) : 'Available cast');
    const role = snapshot?.cast_role || roleAtWeek(member);
    return { member, role, teamId, teamName, points: contributions.get(member.id) || 0 };
  });
  const teamTotals = new Map();
  detailRows.forEach((row) => { if (row.teamId) teamTotals.set(row.teamName, (teamTotals.get(row.teamName) || 0) + row.points); });
  const teamLeaders = [...teamTotals].sort((a, b) => b[1] - a[1]);
  const topTeamScore = teamLeaders[0]?.[1] || 0;
  const topTeams = topTeamScore > 0 ? teamLeaders.filter(([, points]) => points === topTeamScore).map(([name]) => name) : [];
  const sortedRows = [...detailRows].sort((a, b) => b.points - a.points || a.member.name.localeCompare(b.member.name));
  const teamSpotlight = detailRows.length ? `<section class="dance-team-spotlight"><span>Top fantasy team${topTeams.length === 1 ? '' : 's'}</span><strong>${escapeHtml(topTeams.join(' & ') || 'No points recorded')}</strong><small>${topTeamScore ? `${topTeamScore} point${topTeamScore === 1 ? '' : 's'} earned from this dance` : 'Fantasy impact will appear when scoring is available.'}</small></section>` : '';
  const castImpact = `<section class="detail-section"><div class="detail-section-title"><h3>Cast & fantasy impact</h3>${detailRows.length ? `<span>${detailRows.length} cast member${detailRows.length === 1 ? '' : 's'}</span>` : ''}</div>${detailRows.length ? `<div class="dance-cast-impact-list">${sortedRows.map((row) => `<button type="button" data-dance-cast-profile="${row.member.id}"><img src="${escapeHtml(displayImagePath(row.member))}" style="object-position:${row.member.image_position ?? 50}% center" alt=""><span><b>${escapeHtml(row.member.name)}</b><small>${escapeHtml(displayRole({ ...row.member, role: row.role }))} · ${escapeHtml(row.teamName)}</small></span><strong>${row.points ? `+${row.points}` : '—'}</strong><i aria-hidden="true">›</i></button>`).join('')}</div>` : '<p class="sub">No cast appearances were recorded for this dance.</p>'}</section>`;
  openModal(`<div class="dance-detail-head"><p class="eyebrow">${dance.kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h2>${escapeHtml(title)}</h2>${dance.kind === 'competitive' ? `<p class="sub">${escapeHtml(dance.dance_type || 'Dance type not set')}${dance.song ? ` · ${escapeHtml(dance.song)}` : ''}</p>` : ''}</div>${dance.kind === 'competitive' ? `<section class="detail-section dance-score-section"><div class="detail-section-title"><h3>Judges’ scores</h3><strong>${scoreTotal || '—'}</strong></div><div class="detail-judges">${scores.map((score) => `<div><img src="${judgeScoreImage(score.score)}" alt="${escapeHtml(score.judge_name)}: ${score.score}"><span>${escapeHtml(score.judge_name)}</span></div>`).join('') || '<p class="sub">No scores entered.</p>'}</div></section>` : ''}${teamSpotlight}${castImpact}`);
  document.querySelectorAll('[data-dance-cast-profile]').forEach((button) => button.addEventListener('click', () => openCastDetail(button.dataset.danceCastProfile, null, () => openDanceDetail(week, dance, index, pairData, scores, cast, context))));
}

async function openWeekLedger(week) {
  if (!canManageShow) return alert('Platform-owner access is required to open the Week Ledger.');
  const [membersResult, teamsResult, rolesResult, weeksResult, partnershipsResult, dancesResult] = await Promise.all([
    db.from('cast_members').select('*').order('name'),
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('league_id', defaultLeagueId),
    db.from('roles').select('name,appearance_points'),
    db.from('weeks').select('*').order('number'),
    db.from('partnerships').select('id,star_id,pro_id').eq('active', true),
    db.from('dances').select('id,kind,partnership_id,name,sort_order,week_id').eq('week_id', week.id).order('sort_order'),
  ]);
  let error = [membersResult, teamsResult, rolesResult, weeksResult, partnershipsResult, dancesResult].find((result) => result.error)?.error;
  if (error) return alert(`Couldn’t load the week ledger: ${error.message}`);
  const danceIds = dancesResult.data.map((dance) => dance.id);
  const [scoresResult, appearancesResult] = danceIds.length ? await Promise.all([
    db.from('dance_judge_scores').select('dance_id,score').in('dance_id', danceIds),
    db.from('dance_appearances').select('id,dance_id,cast_member_id').in('dance_id', danceIds),
  ]) : [{ data: [], error: null }, { data: [], error: null }];
  error = scoresResult.error || appearancesResult.error;
  if (error) return alert(`Couldn’t load the week ledger: ${error.message}`);
  let snapshots = [];
  if (Object.prototype.hasOwnProperty.call(week, 'is_complete')) {
    const { data, error: snapshotError } = await db.from('weekly_roster_snapshots').select('*').eq('league_id', defaultLeagueId).eq('week_id', week.id);
    if (snapshotError) return alert(`Couldn’t load the week roster: ${snapshotError.message}`);
    snapshots = data;
  }
  const data = { teams: teamsResult.data, members: membersResult.data, roles: rolesResult.data, weeks: weeksResult.data, partnerships: partnershipsResult.data, dances: dancesResult.data, scores: scoresResult.data, appearances: appearancesResult.data, rosterSnapshots: snapshots };
  const { weekMemberPoints } = calculateLeaguePoints(data);
  const snapshotByMember = new Map(snapshots.map((snapshot) => [snapshot.cast_member_id, snapshot]));
  const teamById = new Map(teamsResult.data.map((team) => [team.id, team]));
  const roleMap = new Map(rolesResult.data.map((role) => [role.name, role.appearance_points]));
  let mode = 'competitive';
  let selectedMemberId = '';
  const draw = () => {
    const rows = membersResult.data.map((member) => {
      const snapshot = snapshotByMember.get(member.id);
      const entry = weekMemberPoints.get(week.id)?.get(member.id) || { official: 0, appearances: 0, appearanceCount: 0, appearanceRates: [] };
      const role = snapshot?.cast_role || roleForWeek(member, week, weeksResult.data);
      const team = snapshot ? { manager_name: snapshot.manager_name, team_name: snapshot.team_name } : teamById.get(member.fantasy_team_id);
      const rate = member.is_hough ? Number(roleMap.get('Hough')) || 0 : role === 'Surprise' ? Number(member.custom_appearance_points) || 0 : Number(roleMap.get(role)) || 0;
      return { member, role, team, rate, ...entry, total: entry.official + entry.appearances };
    }).sort((a, b) => b.total - a.total || a.member.name.localeCompare(b.member.name));
    const total = rows.reduce((sum, row) => sum + row.total, 0);
    const danceLabels = new Map(dancesResult.data.map((dance, index) => [dance.id, dance.kind === 'performance' ? dance.name || `Week ${week.number} Dance ${index + 1}` : (() => { const pair = partnershipsResult.data.find((item) => item.id === dance.partnership_id); const star = membersResult.data.find((member) => member.id === pair?.star_id); const pro = membersResult.data.find((member) => member.id === pair?.pro_id); return star && pro ? `${star.name} & ${pro.name}` : `Competitive Dance ${index + 1}`; })()]));
    const competitiveDances = dancesResult.data.filter((dance) => dance.kind === 'competitive');
    const selectedMember = membersResult.data.find((member) => member.id === selectedMemberId);
    const weekDanceIds = new Set(dancesResult.data.map((dance) => dance.id));
    const memberAppearances = selectedMember ? appearancesResult.data.filter((appearance) => appearance.cast_member_id === selectedMember.id && weekDanceIds.has(appearance.dance_id)) : [];
    const usedDanceIds = new Set(memberAppearances.map((appearance) => appearance.dance_id));
    const availableDances = dancesResult.data.filter((dance) => !usedDanceIds.has(dance.id));
    const competitiveBody = `<section class="ledger-dances"><h3>Competitive dances</h3>${competitiveDances.map((dance) => `<div><span>${escapeHtml(danceLabels.get(dance.id))}</span>${canManageShow ? `<button class="secondary" data-ledger-dance="${dance.id}">Edit scores</button>` : ''}</div>`).join('') || '<p class="sub">No competitive dances recorded.</p>'}</section>`;
    const performanceBody = `<section class="ledger-performance"><input id="ledgerCastSearch" placeholder="Search cast member" autocomplete="off"><div class="ledger-cast-list">${[...rows].sort((a, b) => a.member.name.localeCompare(b.member.name)).map((row) => `<button class="ledger-cast-choice ${row.member.id === selectedMemberId ? 'selected' : ''}" data-ledger-member="${row.member.id}" data-ledger-name="${escapeHtml(row.member.name.toLowerCase())}"><span>${escapeHtml(row.member.name)}</span><small>${escapeHtml(displayRole({ ...row.member, role: row.role }))} · ${row.appearanceCount} appearance${row.appearanceCount === 1 ? '' : 's'}</small></button>`).join('')}</div>${selectedMember ? `<section class="ledger-member-editor"><p class="eyebrow">Selected cast member</p><h3>${escapeHtml(selectedMember.name)}</h3><p class="ledger-member-summary">${memberAppearances.length} recorded appearance${memberAppearances.length === 1 ? '' : 's'} this week</p><div class="ledger-action-block"><label>Remove from dance<select id="ledgerRemoveDance"><option value="">Select recorded dance</option>${memberAppearances.map((appearance) => `<option value="${appearance.id}">${escapeHtml(danceLabels.get(appearance.dance_id) || 'Dance')}</option>`).join('')}</select></label><button class="secondary" id="removeLedgerAppearance">Remove appearance</button></div><div class="ledger-action-block"><label>Add to existing dance<select id="ledgerAddDance"><option value="">Select dance</option>${availableDances.map((dance) => `<option value="${dance.id}">${escapeHtml(danceLabels.get(dance.id) || 'Dance')}</option>`).join('')}</select></label><button id="addLedgerAppearance">Add appearance</button></div>${canManageShow ? '<div class="ledger-new-performance"><span>Missing a performance?</span><button class="secondary" id="addLedgerPerformance">Create performance dance</button></div>' : ''}</section>` : '<p class="sub ledger-prompt">Select a cast member to edit their recorded dance appearances.</p>'}</section>`;
    const eliminationFormat = `${week.is_finale ? 'No elimination' : week.double_elimination ? 'Double elimination' : 'Standard elimination'}${week.is_season_finale ? ' · Season finale' : ''}`;
    const weekDetails = `<section class="ledger-week-details"><div class="ledger-section-heading"><div><p class="eyebrow">Week details</p><h3>Show information</h3></div><button id="editLedgerWeekDetails" class="secondary">Edit details</button></div><div id="ledgerWeekSummary" class="ledger-detail-summary"><span><small>Title</small><b>${escapeHtml(week.title || 'No custom title')}</b></span><span><small>Theme</small><b>${escapeHtml(week.theme || 'No theme')}</b></span><span><small>Airing</small><b>${escapeHtml(weekAiringLabel(week, 'Date TBA'))}</b></span><span><small>Format</small><b>${escapeHtml(eliminationFormat)}</b></span><span><small>Guest judge</small><b>${escapeHtml(week.guest_judge_name || 'None')}</b></span></div><div id="ledgerWeekEditor" hidden><div class="ledger-field-group"><p class="eyebrow">Episode</p><div class="week-inline-fields"><label>Theme <span class="optional">(optional)</span><input id="ledgerWeekTheme" value="${escapeHtml(week.theme || '')}"></label><label>Week title <span class="optional">(optional)</span><input id="ledgerWeekTitle" value="${escapeHtml(week.title || '')}" placeholder="Optional custom title"></label></div></div><div class="ledger-field-group"><p class="eyebrow">Schedule</p><div class="week-inline-fields"><label>Airing<select id="ledgerAiringFormat"><option value="one" ${week.second_air_date ? '' : 'selected'}>One night</option><option value="two" ${week.second_air_date ? 'selected' : ''}>Two nights</option></select></label><label>First night date <span class="optional">(optional)</span><input id="ledgerWeekAirDate" type="date" value="${escapeHtml(week.air_date || '')}"></label><label id="ledgerSecondAirDateField" ${week.second_air_date ? '' : 'hidden'}>Second night date<input id="ledgerWeekSecondAirDate" type="date" value="${escapeHtml(week.second_air_date || '')}"></label></div></div><div class="ledger-field-group"><p class="eyebrow">Episode format</p><div class="week-inline-fields"><label>Elimination<select id="ledgerEliminationFormat"><option value="standard" ${!week.double_elimination && !week.is_finale ? 'selected' : ''}>Standard elimination</option><option value="double" ${week.double_elimination ? 'selected' : ''}>Double elimination</option><option value="none" ${week.is_finale ? 'selected' : ''}>No elimination</option></select></label><label class="check-label"><input id="ledgerGuestJudgeEnabled" type="checkbox" ${week.guest_judge_name ? 'checked' : ''}> Guest judge</label><label id="ledgerGuestJudgeField" ${week.guest_judge_name ? '' : 'hidden'}>Guest judge name<input id="ledgerGuestJudgeName" value="${escapeHtml(week.guest_judge_name || '')}"></label></div></div><p class="ledger-details-note">The elimination format must still match the result already recorded for this completed week.</p><div class="ledger-detail-actions"><button id="cancelLedgerWeekDetails" class="secondary">Cancel</button><button id="saveLedgerWeekDetails">Save details</button></div></div></section>`;
    $('#weekLedgerBody').innerHTML = `<div class="breakdown-head"><div><p class="eyebrow">Week ${week.number} ledger</p><h2>${escapeHtml(weekTitle(week))}</h2><p class="sub">Correct completed-week scoring and show details here. Role rates always come from the league-wide Rules tab.</p></div><div class="breakdown-total"><strong>${total}</strong><span>league points</span></div></div>${weekDetails}<div class="filter-tabs ledger-mode-tabs"><button class="${mode === 'competitive' ? 'selected' : ''}" data-ledger-mode="competitive">Competitive</button><button class="${mode === 'performance' ? 'selected' : ''}" data-ledger-mode="performance">Performance</button></div>${mode === 'competitive' ? competitiveBody : performanceBody}`;
    $('#ledgerEliminationFormat').closest('.week-inline-fields').insertAdjacentHTML('beforeend', `<label class="check-label"><input id="ledgerSeasonFinale" type="checkbox" ${week.is_season_finale ? 'checked' : ''}> Season finale</label>`);
    $('#editLedgerWeekDetails').addEventListener('click', () => { $('#ledgerWeekSummary').hidden = true; $('#ledgerWeekEditor').hidden = false; $('#editLedgerWeekDetails').hidden = true; });
    $('#cancelLedgerWeekDetails').addEventListener('click', draw);
    $('#ledgerAiringFormat').addEventListener('change', (event) => { const twoNights = event.target.value === 'two'; $('#ledgerSecondAirDateField').hidden = !twoNights; if (!twoNights) $('#ledgerWeekSecondAirDate').value = ''; });
    $('#ledgerGuestJudgeEnabled').addEventListener('change', (event) => { $('#ledgerGuestJudgeField').hidden = !event.target.checked; if (!event.target.checked) $('#ledgerGuestJudgeName').value = ''; });
    $('#saveLedgerWeekDetails').addEventListener('click', async () => {
      const theme = $('#ledgerWeekTheme').value.trim() || null;
      const title = $('#ledgerWeekTitle').value.trim() || null;
      const airDate = $('#ledgerWeekAirDate').value || null;
      const twoNights = $('#ledgerAiringFormat').value === 'two';
      const secondAirDate = twoNights ? $('#ledgerWeekSecondAirDate').value || null : null;
      const guestJudge = $('#ledgerGuestJudgeEnabled').checked ? $('#ledgerGuestJudgeName').value.trim() || null : null;
      const selectedElimination = $('#ledgerEliminationFormat').value;
      const noElimination = selectedElimination === 'none';
      const doubleElimination = selectedElimination === 'double';
      if (twoNights && (!airDate || !secondAirDate)) return alert('Choose both airing dates for a two-night week.');
      if (secondAirDate && secondAirDate < airDate) return alert('The second night cannot be before the first night.');
      if ($('#ledgerGuestJudgeEnabled').checked && !guestJudge) return alert('Enter the guest judge’s name.');
      if (['Carrie Ann', 'Derek', 'Bruno'].some((name) => name.toLowerCase() === guestJudge?.toLowerCase())) return alert('The guest judge needs a different name from the regular judges.');
      const saveButton = $('#saveLedgerWeekDetails');
      saveButton.disabled = true;
      const seasonFinale = $('#ledgerSeasonFinale').checked;
      const { error: saveError } = await db.rpc('update_completed_week_details_and_finale', { p_week_id: week.id, p_theme: theme, p_title: title, p_air_date: airDate, p_second_air_date: secondAirDate, p_guest_judge_name: guestJudge, p_double_elimination: doubleElimination, p_is_finale: noElimination, p_is_season_finale: seasonFinale });
      saveButton.disabled = false;
      if (missingRpc(saveError)) return alert('Run the cast source and league settings SQL migration in Supabase before saving these details.');
      if (saveError) return alert(`Couldn’t save Week ${week.number}: ${saveError.message}`);
      Object.assign(week, { theme, title, air_date: airDate, second_air_date: secondAirDate, guest_judge_name: guestJudge, double_elimination: doubleElimination, is_finale: noElimination, is_season_finale: seasonFinale });
      Object.assign(weeksResult.data.find((item) => item.id === week.id) || {}, week);
      draw();
      loadScoreDesk();
      loadStandings();
    });
    document.querySelectorAll('[data-ledger-mode]').forEach((button) => button.addEventListener('click', () => { mode = button.dataset.ledgerMode; draw(); }));
    document.querySelectorAll('[data-ledger-dance]').forEach((button) => { const dance = dancesResult.data.find((item) => item.id === button.dataset.ledgerDance); button.addEventListener('click', () => openEditDance(week, dance, dancesResult.data.indexOf(dance), true)); });
    document.querySelectorAll('[data-ledger-member]').forEach((button) => button.addEventListener('click', () => { selectedMemberId = button.dataset.ledgerMember; draw(); }));
    $('#ledgerCastSearch')?.addEventListener('input', (event) => { const term = event.target.value.toLowerCase(); document.querySelectorAll('[data-ledger-name]').forEach((button) => { button.hidden = !button.dataset.ledgerName.includes(term); }); });
    $('#removeLedgerAppearance')?.addEventListener('click', async () => { const id = $('#ledgerRemoveDance').value; if (!id) return alert('Choose the recorded dance first.'); const { error } = await db.from('dance_appearances').delete().eq('id', id); if (error) return alert(`Couldn’t remove the appearance: ${error.message}`); $('#modal').close(); loadScoreDesk(); loadStandings(); });
    $('#addLedgerAppearance')?.addEventListener('click', async () => { const danceId = $('#ledgerAddDance').value; if (!danceId) return alert('Choose the dance first.'); const { error } = await db.from('dance_appearances').insert({ dance_id: danceId, cast_member_id: selectedMember.id }); if (error) return alert(`Couldn’t add the appearance: ${error.message}`); $('#modal').close(); loadScoreDesk(); loadStandings(); });
    $('#addLedgerPerformance')?.addEventListener('click', () => openNewDance(week, dancesResult.data.length, null, [], [], 'performance'));
  };
  openModal('<div id="weekLedgerBody"></div>');
  draw();
}

async function openNewWeek() {
  const { data: existing, error } = await db.from('weeks').select('number,is_season_finale').order('number', { ascending: false }).limit(1);
  if (error) return alert(`Couldn’t prepare a new week: ${error.message}`);
  if (existing[0]?.is_season_finale) return alert('The season finale is already scheduled. Unmark it before adding another week.');
  const number = (existing[0]?.number || 0) + 1;
  openModal(`<h2>Add Week ${number}</h2><label>Theme <span class="optional">(optional)</span><input id="weekTheme" autocomplete="off"></label><label>Week title <span class="optional">(optional)</span><input id="weekTitle" placeholder="Optional custom title" autocomplete="off"></label><label>Air date <span class="optional">(optional)</span><input id="weekAirDate" type="date"></label><label class="check-label"><input id="twoNightAiring" type="checkbox"> Two-night airing</label><label id="secondAirDateField" hidden>Second night date<input id="weekSecondAirDate" type="date"></label><label class="check-label"><input id="guestJudgeEnabled" type="checkbox"> Guest judge</label><label id="guestJudgeField" hidden>Guest judge name<input id="guestJudgeName" autocomplete="off"></label><label class="check-label"><input id="doubleElimination" type="checkbox"> Double elimination</label><label class="check-label"><input id="isFinale" type="checkbox"> No elimination</label><label class="check-label"><input id="isSeasonFinale" type="checkbox"> Season finale</label><div class="modal-actions"><button id="createWeek">Create Week ${number}</button></div>`);
  $('#twoNightAiring').addEventListener('change', (event) => { $('#secondAirDateField').hidden = !event.target.checked; if (!event.target.checked) $('#weekSecondAirDate').value = ''; });
  $('#guestJudgeEnabled').addEventListener('change', (event) => { $('#guestJudgeField').hidden = !event.target.checked; });
  $('#isFinale').addEventListener('change', (event) => { $('#doubleElimination').disabled = event.target.checked; if (event.target.checked) $('#doubleElimination').checked = false; });
  $('#createWeek').addEventListener('click', async () => {
    const theme = $('#weekTheme').value.trim();
    const title = $('#weekTitle').value.trim() || null;
    const air_date = $('#weekAirDate').value || null;
    const second_air_date = $('#twoNightAiring').checked ? $('#weekSecondAirDate').value || null : null;
    const guest_judge_name = $('#guestJudgeEnabled').checked ? $('#guestJudgeName').value.trim() || null : null;
    if ($('#twoNightAiring').checked && (!air_date || !second_air_date)) return alert('Choose both airing dates for a two-night week.');
    if (second_air_date && second_air_date < air_date) return alert('The second night cannot be before the first night.');
    if ($('#guestJudgeEnabled').checked && !guest_judge_name) return alert('Enter the guest judge’s name.');
    if (['Carrie Ann', 'Derek', 'Bruno'].some((name) => name.toLowerCase() === guest_judge_name?.toLowerCase())) return alert('The guest judge needs a different name from the regular judges.');
    const createButton = $('#createWeek');
    createButton.disabled = true;
    const { data: week, error: createError } = await db.from('weeks').insert({ number, theme: theme || null, title, air_date, second_air_date, guest_judge_name, double_elimination: $('#doubleElimination').checked, is_finale: $('#isFinale').checked, is_season_finale: $('#isSeasonFinale').checked }).select().single();
    if (createError) { createButton.disabled = false; return alert(`Couldn’t create Week ${number}: ${createError.message}`); }
    selectedWeekId = week.id; $('#modal').close(); loadScoreDesk();
  });
}

const missingRpc = (error) => error?.code === 'PGRST202' || /could not find the function|function .* does not exist/i.test(error?.message || '');

async function saveInlineWeek(week, dances) {
  const theme = $('#weekTheme').value.trim();
  const title = $('#weekTitle').value.trim() || null;
  const airDate = $('#weekAirDate').value || null;
  const secondAirDate = $('#twoNightAiring').checked ? $('#weekSecondAirDate').value || null : null;
  const guestJudge = $('#guestJudgeEnabled').checked ? $('#guestJudgeName').value.trim() : '';
  if ($('#twoNightAiring').checked && (!airDate || !secondAirDate)) return alert('Choose both airing dates for a two-night week.');
  if (secondAirDate && secondAirDate < airDate) return alert('The second night cannot be before the first night.');
  if ($('#guestJudgeEnabled').checked && !guestJudge) return alert('Enter the guest judge’s name.');
  if (['Carrie Ann', 'Derek', 'Bruno'].some((name) => name.toLowerCase() === guestJudge.toLowerCase())) return alert('The guest judge needs a different name from the regular judges.');
  const isFinale = $('#isFinale').checked;
  const danceIds = [...document.querySelectorAll('#scoreDeskContent [data-reorder-id]')].map((row) => row.dataset.reorderId);
  const payload = { p_week_id: week.id, p_theme: theme || null, p_title: title, p_guest_judge_name: guestJudge || null, p_double_elimination: !isFinale && $('#doubleElimination').checked, p_is_finale: isFinale, p_dance_ids: danceIds, p_air_date: airDate, p_second_air_date: secondAirDate, p_is_season_finale: $('#isSeasonFinale').checked };
  const saveButton = $('#saveWeek'); saveButton.disabled = true;
  const { error } = await db.rpc('update_week_setup_and_finale', payload);
  if (missingRpc(error)) {
    saveButton.disabled = false;
    return alert('Run the cast source and league settings SQL migration in Supabase before saving week details.');
  }
  saveButton.disabled = false;
  if (error) return alert(`Couldn’t save Week ${week.number}: ${error.message}`);
  editingWeekId = null;
  loadScoreDesk(); loadRoster(); loadStandings();
}

function attachDanceReorder() {
  const list = $('#scoreDeskContent .dance-list');
  let activeRow = null;
  let startY = 0;
  list.addEventListener('pointerdown', (event) => {
    const handle = event.target.closest('.dance-drag-handle');
    if (!handle || (event.button !== 0 && event.pointerType === 'mouse')) return;
    event.preventDefault();
    activeRow = handle.closest('[data-reorder-id]');
    startY = event.clientY;
    list.setPointerCapture(event.pointerId);
    activeRow.classList.add('is-dragging');
    handle.focus();
  });
  list.addEventListener('pointermove', (event) => {
    if (!activeRow || !list.hasPointerCapture(event.pointerId) || Math.abs(event.clientY - startY) < 3) return;
    if (event.clientY < 60) window.scrollBy(0, -18);
    if (event.clientY > window.innerHeight - 60) window.scrollBy(0, 18);
    const target = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-reorder-id]');
    if (!target || target === activeRow || target.parentElement !== list) return;
    const midpoint = target.getBoundingClientRect().top + target.offsetHeight / 2;
    list.insertBefore(activeRow, event.clientY < midpoint ? target : target.nextSibling);
  });
  const release = () => { activeRow?.classList.remove('is-dragging'); activeRow = null; };
  list.addEventListener('pointerup', release);
  list.addEventListener('pointercancel', release);
  list.querySelectorAll('.dance-drag-handle').forEach((handle) => {
    const row = handle.closest('[data-reorder-id]');
    handle.addEventListener('keydown', (event) => {
      if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
      event.preventDefault();
      if (event.key === 'ArrowUp' && row.previousElementSibling) list.insertBefore(row, row.previousElementSibling);
      if (event.key === 'ArrowDown' && row.nextElementSibling) list.insertBefore(row.nextElementSibling, row);
      handle.focus();
    });
  });
}

async function openCompleteWeek(week) {
  const { players, partnerships } = await getPairingData();
  const { data: competitiveDances, error } = await db.from('dances').select('partnership_id').eq('week_id', week.id).eq('kind', 'competitive');
  if (error) return alert(`Couldn’t prepare completion: ${error.message}`);
  const dancedPairIds = new Set(competitiveDances.map((dance) => dance.partnership_id));
  const eligiblePairs = partnerships.filter((pair) => dancedPairIds.has(pair.id)).map((pair) => {
    const star = players.find((player) => player.id === pair.star_id);
    const pro = players.find((player) => player.id === pair.pro_id);
    return { ...pair, label: star && pro ? `${star.name} & ${pro.name}` : 'Unnamed couple' };
  }).sort((a, b) => a.label.localeCompare(b.label));
  const requiredEliminations = week.is_finale ? 0 : week.double_elimination ? 2 : 1;
  openModal(`<h2>Mark ${escapeHtml(weekTitle(week))} Complete</h2><p class="sub">This captures the week’s roster and appearance rates, then applies any eliminations after its scoring. You can still correct dances and scores later.</p>${requiredEliminations ? `<label>Eliminated couple<select id="completeEliminationOne"><option value="">Select couple</option>${eligiblePairs.map((pair) => `<option value="${pair.id}">${escapeHtml(pair.label)}</option>`).join('')}</select></label>${requiredEliminations === 2 ? `<label>Second eliminated couple<select id="completeEliminationTwo"><option value="">Select couple</option>${eligiblePairs.map((pair) => `<option value="${pair.id}">${escapeHtml(pair.label)}</option>`).join('')}</select></label>` : ''}` : '<p class="sub">No elimination is recorded for this week.</p>'}<div class="modal-actions"><button id="confirmCompleteWeek">Mark complete</button></div>`);
  $('#confirmCompleteWeek').addEventListener('click', async () => {
    const eliminated = requiredEliminations ? [$('#completeEliminationOne').value, $('#completeEliminationTwo')?.value].filter(Boolean) : [];
    if (eliminated.length !== requiredEliminations) return alert(requiredEliminations === 2 ? 'Choose both eliminated couples.' : 'Choose the eliminated couple.');
    if (new Set(eliminated).size !== eliminated.length) return alert('Choose two different couples.');
    const completeButton = $('#confirmCompleteWeek');
    completeButton.disabled = true;
    const { error: completionError } = await db.rpc('complete_week', { p_week_id: week.id, p_eliminated_partnership_ids: eliminated });
    if (completionError) { completeButton.disabled = false; return alert(`Couldn’t complete the week: ${completionError.message}`); }
    $('#modal').close();
    loadScoreDesk(); loadRoster(); loadTeams(); loadStandings(); loadRules();
  });
}

async function openNewDance(week, danceCount, existingDance = null, existingScores = [], existingAppearanceIds = [], initialKind = null, scoresOnly = false) {
  const { players, partnerships, weeks } = await getPairingData();
  const activePairs = partnerships.filter((pairing) => {
    const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id);
    return roleForWeek(star, week, weeks) === 'Star' && roleForWeek(pro, week, weeks) === 'Pro';
  });
  const { data: scoredDances, error: scoredDancesError } = await db.from('dances').select('partnership_id').eq('week_id', week.id).eq('kind', 'competitive');
  if (scoredDancesError) return alert(`Couldn’t prepare this dance: ${scoredDancesError.message}`);
  const usedPairIds = new Set((scoredDances || []).map((dance) => dance.partnership_id).filter((id) => id !== existingDance?.partnership_id));
  const availablePairs = activePairs.filter((pairing) => !usedPairIds.has(pairing.id));
  const existingPair = partnerships.find((pairing) => pairing.id === existingDance?.partnership_id);
  const selectablePairs = (existingPair && !availablePairs.some((pairing) => pairing.id === existingPair.id) ? [...availablePairs, existingPair] : availablePairs).sort((a, b) => {
    const label = (pairing) => { const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id); return `${star?.name || ''} & ${pro?.name || ''}`; };
    return label(a).localeCompare(label(b));
  });
  const castPicker = (excludedIds = []) => players.filter((player) => !excludedIds.includes(player.id)).map((player) => `<label class="cast-choice" data-dance-cast-name="${escapeHtml(player.name.toLowerCase())}" data-dance-cast-category="${castCategory(player)}" data-dance-bonus-category="${bonusCastCategory(player)}"><input type="checkbox" value="${player.id}" ${existingAppearanceIds.some((appearance) => (appearance.cast_member_id || appearance) === player.id) ? 'checked' : ''}><span><b>${escapeHtml(player.name)}</b><small>${escapeHtml(displayRole(player))}</small></span></label>`).join('');
  const drawForm = (kind) => {
    const judgeNames = ['Carrie Ann', 'Derek', 'Bruno', ...(week.guest_judge_name ? [week.guest_judge_name] : [])];
    const pairOptions = selectablePairs.map((pairing) => { const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id); return `<option value="${pairing.id}" ${pairing.id === existingDance?.partnership_id ? 'selected' : ''}>${escapeHtml(star.name)} & ${escapeHtml(pro.name)}</option>`; }).join('');
    const castEditor = scoresOnly ? '' : `<h3>Cast appearances</h3><input id="danceCastSearch" placeholder="Search cast" autocomplete="off"><div class="filter-tabs" id="danceCastTabs"><button class="selected" data-dance-filter="all">All</button><button data-dance-filter="pros">Pros</button><button data-dance-filter="stars">Stars</button><button data-dance-filter="bonus">Bonus</button></div><div id="bonusDanceFilters" class="mini-filters" hidden><button class="selected" data-dance-bonus-filter="all">All bonus</button><button data-dance-bonus-filter="troupe">Troupe</button><button data-dance-bonus-filter="nextpro">Next Pro</button><button data-dance-bonus-filter="judges">Judges + Hosts</button></div><div id="danceCastPicker" class="cast-picker">${castPicker()}</div>`;
    const competitiveEditor = scoresOnly ? `<p class="sub">Update the individual judge scores for this competitive dance.</p><div class="judge-grid">${judgeNames.map((judge) => `<label>${escapeHtml(judge)}<input data-judge="${escapeHtml(judge)}" type="number" min="0" max="10" step="1" inputmode="numeric" value="${existingScores.find((score) => score.judge_name === judge)?.score ?? ''}"></label>`).join('')}</div>` : `<label class="couple-select">Couple<select id="dancePartnership"><option value="">Select couple</option>${pairOptions}</select></label><div class="dance-details"><label>Dance type <span class="optional">(optional)</span><input id="danceType" value="${escapeHtml(existingDance?.dance_type || '')}" placeholder="e.g., Cha-cha-cha"></label><label>Song <span class="optional">(optional)</span><input id="danceSong" value="${escapeHtml(existingDance?.song || '')}" placeholder="Song title"></label></div><p class="sub judge-hint">You can save the lineup now and enter judges’ scores during the show.</p><div class="judge-grid">${judgeNames.map((judge) => `<label>${escapeHtml(judge)}<input data-judge="${escapeHtml(judge)}" type="number" min="0" max="10" step="1" inputmode="numeric" value="${existingScores.find((score) => score.judge_name === judge)?.score ?? ''}"></label>`).join('')}</div>`;
    $('#danceForm').innerHTML = `${kind === 'competitive' ? competitiveEditor : `<label>Dance name <span class="optional">(optional)</span><input id="danceName" value="${escapeHtml(existingDance?.name || '')}" placeholder="Week ${week.number} Dance ${danceCount + 1}"></label>`}${castEditor}`;
    if (!scoresOnly) {
      let filter = 'all'; let bonusFilter = 'all'; let excluded = [];
      const filterCast = () => { const term = $('#danceCastSearch').value.toLowerCase(); document.querySelectorAll('[data-dance-cast-name]').forEach((item) => { const memberId = item.querySelector('input').value; item.hidden = !item.dataset.danceCastName.includes(term) || (filter !== 'all' && item.dataset.danceCastCategory !== filter) || (filter === 'bonus' && bonusFilter !== 'all' && item.dataset.danceBonusCategory !== bonusFilter) || excluded.includes(memberId); }); };
      $('#danceCastSearch').addEventListener('input', filterCast);
      document.querySelectorAll('[data-dance-filter]').forEach((button) => button.addEventListener('click', () => { filter = button.dataset.danceFilter; $('#bonusDanceFilters').hidden = filter !== 'bonus'; document.querySelectorAll('[data-dance-filter]').forEach((item) => item.classList.toggle('selected', item === button)); filterCast(); }));
      document.querySelectorAll('[data-dance-bonus-filter]').forEach((button) => button.addEventListener('click', () => { bonusFilter = button.dataset.danceBonusFilter; document.querySelectorAll('[data-dance-bonus-filter]').forEach((item) => item.classList.toggle('selected', item === button)); filterCast(); }));
      $('#dancePartnership')?.addEventListener('change', (event) => { const pairing = selectablePairs.find((item) => item.id === event.target.value); excluded = pairing ? [pairing.star_id, pairing.pro_id] : []; document.querySelectorAll('#danceCastPicker input').forEach((input) => { if (excluded.includes(input.value)) input.checked = false; }); filterCast(); });
    }
  };
  const startingKind = initialKind || existingDance?.kind || (availablePairs.length ? 'competitive' : 'performance');
  const kindTabs = scoresOnly ? '' : `<div class="filter-tabs dance-kind-tabs"><button ${(initialKind === 'performance' || (!availablePairs.length && !existingDance)) ? 'disabled' : ''} class="${startingKind === 'competitive' ? 'selected' : ''}" data-dance-kind="competitive">Competitive</button><button class="${startingKind === 'performance' ? 'selected' : ''}" data-dance-kind="performance">Performance</button></div>`;
  openModal(`<h2>${scoresOnly ? 'Edit Scores' : existingDance ? 'Edit Dance' : 'Add Dance'}</h2>${kindTabs}<div id="danceForm"></div><div class="modal-actions"><button id="saveDance">${scoresOnly ? 'Save scores' : existingDance ? 'Save changes' : 'Save dance'}</button>${existingDance && !scoresOnly ? '<button id="deleteDance" class="danger">Delete dance</button>' : ''}</div>`);
  let kind = startingKind; drawForm(kind);
  document.querySelectorAll('[data-dance-kind]').forEach((button) => button.addEventListener('click', () => { if (button.disabled) return; kind = button.dataset.danceKind; document.querySelectorAll('[data-dance-kind]').forEach((item) => item.classList.toggle('selected', item === button)); drawForm(kind); }));
  $('#saveDance').addEventListener('click', async () => {
    const partnership_id = kind === 'competitive' ? (scoresOnly ? existingDance.partnership_id : $('#dancePartnership').value || null) : null;
    if (kind === 'competitive' && !partnership_id) return alert('Select the competing couple.');
    const name = kind === 'performance' ? $('#danceName').value.trim() || null : null;
    const dance_type = kind === 'competitive' ? (scoresOnly ? existingDance.dance_type : $('#danceType').value.trim() || null) : null;
    const song = kind === 'competitive' ? (scoresOnly ? existingDance.song : $('#danceSong').value.trim() || null) : null;
    const scoreInputs = kind === 'competitive' ? [...document.querySelectorAll('[data-judge]')].filter((input) => input.value !== '') : [];
    if (scoreInputs.some((input) => !Number.isInteger(Number(input.value)) || Number(input.value) < 0 || Number(input.value) > 10)) return alert('Each judge score must be a whole number from 0 to 10.');
    const selectedAppearanceIds = scoresOnly ? existingAppearanceIds.map((appearance) => appearance.cast_member_id || appearance) : [...document.querySelectorAll('#danceCastPicker input:checked')].map((input) => input.value);
    const saveButton = $('#saveDance'); saveButton.disabled = true;
    const atomicSave = await db.rpc('save_dance_atomic', {
      p_week_id: week.id, p_dance_id: existingDance?.id || null, p_kind: kind, p_partnership_id: partnership_id,
      p_name: name, p_dance_type: dance_type, p_song: song,
      p_judge_scores: scoreInputs.map((input) => ({ judge_name: input.dataset.judge, score: Number(input.value) })),
      p_cast_member_ids: selectedAppearanceIds, p_scores_only: scoresOnly,
    });
    if (!atomicSave.error) { $('#modal').close(); loadScoreDesk(); loadRoster(); loadStandings(); return; }
    saveButton.disabled = false;
    const migrationHint = missingRpc(atomicSave.error) ? ' Run the current workflow-hardening SQL migration first.' : '';
    alert(`Couldn’t save this dance: ${atomicSave.error.message}${migrationHint}`);
  });
  $('#deleteDance')?.addEventListener('click', () => openConfirmation({ title: 'Delete this dance?', message: 'All recorded scores and appearances for this dance will also be deleted. This cannot be undone.', confirmLabel: 'Delete dance', destructive: true, onCancel: () => openNewDance(week, index, existingDance, existingScores, existingAppearanceIds, initialKind, scoresOnly), onConfirm: async () => { const { error } = await db.from('dances').delete().eq('id', existingDance.id); if (!error) { loadScoreDesk(); loadRoster(); loadStandings(); } return error; } }));
}

async function openEditDance(week, dance, index, scoresOnly = false) {
  const [{ data: scores, error: scoreError }, { data: appearances, error: appearanceError }] = await Promise.all([
    db.from('dance_judge_scores').select('id,judge_name,score').eq('dance_id', dance.id),
    db.from('dance_appearances').select('id,cast_member_id').eq('dance_id', dance.id),
  ]);
  if (scoreError || appearanceError) return alert(`Couldn’t open this dance: ${scoreError?.message || appearanceError?.message}`);
  openNewDance(week, index, dance, scores, appearances, null, scoresOnly);
}

async function loadRules() {
  if (!$('#roleRatesContent')) return;
  const loadVersion = ++loadVersions.rules;
  $('#roleRatesContent').innerHTML = loadingMarkup('Loading role rates');
  const { data: roleRows, error } = await db.from('roles').select('name,appearance_points');
  if (loadVersion !== loadVersions.rules) return;
  if (error) {
    console.error(error);
    renderLoadError($('#roleRatesContent'), 'load role rates', loadRules);
    return;
  }
  const roleOrder = ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro', 'Troupe', 'DWTS Next Pro', 'Hough', 'Judges + Hosts', 'Surprise'];
  const rates = [...roleRows].sort((a, b) => (roleOrder.indexOf(a.name) - roleOrder.indexOf(b.name)) || a.name.localeCompare(b.name));
  $('#roleRatesContent').innerHTML = `<div class="role-rate-grid">${rates.map((role) => `<div class="card role-rate-item"><span>${escapeHtml(role.name === 'Judges + Hosts' ? 'Judge / Host' : displayRole(role.name))}${role.name === 'Surprise' ? ' *' : ''}</span><strong>${role.name === 'Surprise' ? 'Varies' : `+${Number(role.appearance_points) || 0}`}</strong></div>`).join('')}</div><p class="surprise-rate-note">* Surprise cast is added as seen on the show. Its custom rate is set on that cast member.</p>`;
  $('#editRules').hidden = !canEdit || !supportsDatabaseHardening;
  $('#editRules').onclick = () => openRulesEditor(rates);
}

function openRulesSummary() {
  openModal(`<div class="rules-summary"><p class="eyebrow">Mirrorball Fantasy League</p><h2>Rules & Scoring</h2><p class="sub">The short version of how your roster earns points.</p><div class="rules-summary-list"><article><b>Competitive dances</b><p>Both members of a competing couple receive the total of the official judges’ scores.</p></article><article><b>Cast appearances</b><p>Cast appearing in another recorded dance earns the appearance rate for their role.</p></article><article><b>Eliminations</b><p>A couple keeps its regular roles through elimination night. Eliminated-role rates begin the following week.</p></article><article><b>Surprise cast</b><p>Surprise additions use a custom appearance rate set by the commissioner.</p></article></div><p class="rules-summary-note">Guest-judge scores count toward competitive totals. Current role rates are listed on the League page.</p></div>`);
}

function openRulesEditor(rates) {
  const editableRates = rates.filter((role) => role.name !== 'Surprise');
  openModal(`<h2>Edit Appearance Rates</h2><p class="sub">These are the default points per recorded dance appearance. Surprise cast keeps a per-person custom rate in the Cast Roster.</p><div class="rate-editor">${editableRates.map((role) => `<label>${escapeHtml(role.name)}<input type="number" min="0" max="99" step="1" inputmode="numeric" data-role-rate="${escapeHtml(role.name)}" value="${Number(role.appearance_points) || 0}"></label>`).join('')}</div><div class="modal-actions"><button id="saveRules">Save rules</button></div>`);
  $('#saveRules').addEventListener('click', async () => {
    const saveButton = $('#saveRules');
    if (saveButton.disabled) return;
    saveButton.disabled = true;
    const edits = [...document.querySelectorAll('[data-role-rate]')].map((input) => ({ name: input.dataset.roleRate, appearance_points: Number(input.value) }));
    if (edits.some((edit) => !Number.isInteger(edit.appearance_points) || edit.appearance_points < 0 || edit.appearance_points > 99)) { saveButton.disabled = false; return alert('Every appearance rate must be a whole number from 0 to 99.'); }
    const { error } = await db.rpc('update_role_rates_atomic', { p_rates: edits });
    if (error) { saveButton.disabled = false; return alert(`Couldn’t save rules: ${error.message}`); }
    $('#modal').close(); loadRules(); loadStandings();
  });
}

if (isScoreDeskSurface) {
  $('#newWeek').addEventListener('click', openNewWeek);
  window.addEventListener('mirrorball-auth-change', (event) => {
    canManageShow = event.detail.isPlatformAdmin === true;
    $('#newWeek').hidden = !canManageShow;
    if (!canManageShow) {
      $('#weekTabs').innerHTML = '';
      $('#scoreDeskContent').innerHTML = '';
      return;
    }
    loadScoreDesk();
  });
} else if (isCastRosterSurface) {
  $('#rosterSearch').addEventListener('input', loadRoster);
  document.querySelectorAll('[data-roster-filter]').forEach((button) => button.addEventListener('click', () => {
    rosterFilter = button.dataset.rosterFilter;
    document.querySelectorAll('[data-roster-filter]').forEach((item) => item.classList.toggle('selected', item === button));
    loadRoster();
  }));
  $('#newPlayer').addEventListener('click', openAddPlayer);
  window.addEventListener('mirrorball-auth-change', (event) => {
    canManageCast = event.detail.isPlatformAdmin === true;
    $('#newPlayer').hidden = !canManageCast;
    if (canManageCast) loadRoster();
    else $('#rosterResults').innerHTML = '';
  });
} else {
  document.querySelectorAll('[data-league-section]').forEach((button) => button.addEventListener('click', () => {
    document.querySelectorAll('[data-league-section]').forEach((item) => item.classList.toggle('selected', item === button));
    document.getElementById(button.dataset.leagueSection)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }));
  $('#rosterSearch').addEventListener('input', loadRoster);
  document.querySelectorAll('[data-roster-filter]').forEach((button) => button.addEventListener('click', () => {
    rosterFilter = button.dataset.rosterFilter;
    document.querySelectorAll('[data-roster-filter]').forEach((item) => item.classList.toggle('selected', item === button));
    loadRoster();
  }));
  $('#rulesButton').addEventListener('click', openRulesSummary);
  const overviewLayout = $('.overview-layout');
  if (overviewLayout && 'ResizeObserver' in window) {
    new ResizeObserver(() => renderOverviewTeamDetail()).observe(overviewLayout);
  }
  const refreshVisibleTrades = () => {
    if (!document.hidden && $('#tradeCenter')) loadTrades();
  };
  window.addEventListener('focus', refreshVisibleTrades);
  document.addEventListener('visibilitychange', refreshVisibleTrades);
  window.addEventListener('mirrorball-auth-change', async (event) => {
    activeLeagueId = event.detail.leagueId || defaultLeagueId;
    canEdit = event.detail.isCommissioner;
    canManageShow = false;
    canManageCast = false;
    managerTeamId = event.detail.fantasyTeamId;
    managerFirstName = event.detail.firstName || '';
    managerLastName = event.detail.lastName || '';
    managerDisplayName = event.detail.displayName || [managerFirstName, managerLastName].filter(Boolean).join(' ');
    managerTeamName = event.detail.teamName || '';
    managerNavLabelMode = event.detail.teamNavLabelMode || 'default';
    managerCustomNavLabel = event.detail.customTeamNavLabel || '';
    renderLeagueHub(event.detail);
    if (activeLeagueId !== defaultLeagueId && event.detail.signedIn) {
      canEdit = false;
      renderSecondaryLeague(event.detail);
      return;
    }
    stopSecondaryLeague();
    if (managerTeamId) selectedPublicTeamId = managerTeamId;
    loadLeagueSettings();
    loadStandings();
    loadRoster();
    loadTeams();
    loadScoreDesk();
    loadRules();
  });
  window.addEventListener('mirrorball-account-open', (event) => renderLeagueHub(event.detail));
}
