import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const db = createClient('https://mdrrnanxqazecqviaass.supabase.co', 'sb_publishable_ylMIgpLXA0NBoeb3aPI8qQ_m0wrG7It');
const $ = (selector) => document.querySelector(selector);
const roles = ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro', 'Troupe', 'DWTS Next Pro', 'Hough', 'Judges + Hosts', 'Surprise'];
const imagePathFor = (name) => `Images/${name.replace(/[.,'’]/g, '')}.jpg`;
const isPairRole = (role) => role === 'Star' || role === 'Pro';
const isAnyPairRole = (role) => ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro'].includes(role);
const oppositeRole = (role) => role === 'Star' ? 'Pro' : 'Star';
const activePairRole = (role) => role.includes('Star') ? 'Star' : role.includes('Pro') ? 'Pro' : role;
let canEdit = false;
let rosterFilter = 'all';

function castCategory(player) {
  if (player.role === 'Pro' || player.role === 'Eliminated Pro') return 'pros';
  if (player.role === 'Star' || player.role === 'Eliminated Star') return 'stars';
  return 'bonus';
}

function showRosterMessage(message, isError = false) {
  $('#rosterResults').innerHTML = `<p class="sub ${isError ? 'error' : ''}">${message}</p>`;
}

function openModal(contents) {
  $('#modalBody').innerHTML = `<div class="modal">${contents}</div>`;
  $('#modal').showModal();
  $('#modalClose').onclick = () => $('#modal').close();
}

function escapeHtml(value = '') {
  return String(value).replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
}

async function getPairingData() {
  const [{ data: players, error: playerError }, { data: partnerships, error: pairingError }, { data: weeks, error: weekError }] = await Promise.all([
    db.from('players').select('*').order('name'),
    db.from('partnerships').select('id,star_id,pro_id,active').eq('active', true),
    db.from('weeks').select('id,number,label').order('number', { ascending: false }),
  ]);
  if (playerError || pairingError || weekError) throw new Error(playerError?.message || pairingError?.message || weekError?.message);
  return { players, partnerships, weeks };
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
    .map((person) => `<option value="${person.id}" ${person.id === selectedId ? 'selected' : ''}>${person.name}</option>`)
    .join('');
}

async function replacePartnership(player, role, partnerId, partnerships) {
  const current = partnerships.find((item) => item.star_id === player.id || item.pro_id === player.id);
  const currentPartnerId = current && (current.star_id === player.id ? current.pro_id : current.star_id);
  if (currentPartnerId === (partnerId || null)) return null;
  const idsToClear = [player.id, partnerId].filter(Boolean);
  for (const id of idsToClear) {
    const { error } = await db.from('partnerships').delete().or(`star_id.eq.${id},pro_id.eq.${id}`);
    if (error) return error;
  }
  if (!partnerId) return null;
  const row = role === 'Star' ? { star_id: player.id, pro_id: partnerId, active: true } : { star_id: partnerId, pro_id: player.id, active: true };
  const { error } = await db.from('partnerships').insert(row);
  return error;
}

async function loadRoster() {
  const query = $('#rosterSearch').value.trim();
  let rosterData;
  try { rosterData = await getPairingData(); } catch (error) { return showRosterMessage(`Couldn’t load the cast: ${error.message}`, true); }
  const { players: allPlayers, partnerships, weeks } = rosterData;
  const players = allPlayers.filter((player) => player.name.toLowerCase().includes(query.toLowerCase()) && (rosterFilter === 'all' || castCategory(player) === rosterFilter));
  if (!players.length) return showRosterMessage('No cast members yet. Add them manually.');
  $('#rosterResults').innerHTML = players.map((player) => `
    <div class="row"><img class="player-photo" src="${player.image_path || imagePathFor(player.name)}" alt="">
      <span><b>${player.name}</b><small>${rosterDetail(player, partnerships, allPlayers, weeks)}</small></span>
      ${canEdit && isPairRole(player.role) ? `<button class="danger" data-eliminate-id="${player.id}">Eliminate</button>` : ''}
      ${canEdit ? `<button data-player-id="${player.id}">Edit</button>` : ''}
    </div>`).join('');
  document.querySelectorAll('[data-player-id]').forEach((button) => button.addEventListener('click', () => editPlayer(button.dataset.playerId)));
  document.querySelectorAll('[data-eliminate-id]').forEach((button) => button.addEventListener('click', () => eliminatePair(button.dataset.eliminateId)));
}

function rosterDetail(player, partnerships, players, weeks) {
  const partner = partnerFor(player, partnerships, players);
  const base = player.role === 'Surprise' && player.custom_appearance_points ? `Surprise · +${player.custom_appearance_points}` : player.role;
  if (!isAnyPairRole(player.role)) return base;
  const partnerText = partner ? `Partner: ${partner.name}` : '<strong class="missing">No partner assigned</strong>';
  if (!player.role.startsWith('Eliminated')) return `${base} · ${partnerText}`;
  const week = weeks.find((item) => item.id === player.eliminated_week_id);
  return `${base} · ${partnerText} · Eliminated ${week ? `Week ${week.number}` : 'week not set'}`;
}

async function eliminatePair(id) {
  try {
    const { players, partnerships, weeks } = await getPairingData();
    const player = players.find((item) => item.id === id);
    const partner = partnerFor(player, partnerships, players);
    if (!partner) return alert(`Assign ${player.name} a partner before marking them eliminated.`);
    const week = weeks[0];
    const suffix = week ? ` after Week ${week.number}` : ' (the eliminated week will be left unset until you create weeks)';
    if (!confirm(`Mark ${player.name} and ${partner.name} eliminated${suffix}?`)) return;
    const star = player.role === 'Star' ? player : partner;
    const pro = player.role === 'Pro' ? player : partner;
    const [starResult, proResult] = await Promise.all([
      db.from('players').update({ role: 'Eliminated Star', eliminated_week_id: week?.id ?? null }).eq('id', star.id),
      db.from('players').update({ role: 'Eliminated Pro', eliminated_week_id: week?.id ?? null }).eq('id', pro.id),
    ]);
    const error = starResult.error || proResult.error;
    if (error) return alert(`Couldn’t mark the pair eliminated: ${error.message}`);
    loadRoster();
  } catch (error) { alert(`Couldn’t mark this pair eliminated: ${error.message}`); }
}

async function undoElimination(player, partner) {
  if (!partner) return alert('This cast member has no partner assigned, so there is no pair to restore.');
  const star = player.role.includes('Star') ? player : partner;
  const pro = player.role.includes('Pro') ? player : partner;
  const [starResult, proResult] = await Promise.all([
    db.from('players').update({ role: 'Star', eliminated_week_id: null }).eq('id', star.id),
    db.from('players').update({ role: 'Pro', eliminated_week_id: null }).eq('id', pro.id),
  ]);
  const error = starResult.error || proResult.error;
  if (error) return alert(`Couldn’t undo the elimination: ${error.message}`);
  $('#modal').close();
  loadRoster();
}

async function editPlayer(id) {
  try {
    const { players, partnerships } = await getPairingData();
    const player = players.find((item) => item.id === id);
    const partner = partnerFor(player, partnerships, players);
    openModal(`<h2>${player.name}</h2><p class="sub">Their image uses the centered portrait crop in the cast roster.</p>
      <label>Role<select id="editRole">${roles.map((role) => `<option ${role === player.role ? 'selected' : ''}>${role}</option>`).join('')}</select></label>
      <label id="surpriseRate" ${player.role === 'Surprise' ? '' : 'hidden'}>Points per appearance<input id="editRate" type="number" min="0" value="${player.custom_appearance_points ?? ''}"></label>
      <label id="partnerField" ${isAnyPairRole(player.role) ? '' : 'hidden'}>Partner<select id="editPartner"><option value="">No partner</option>${partnerOptions(activePairRole(player.role), players, partnerships, partner?.id)}</select></label>
      ${player.role.startsWith('Eliminated') ? '<button id="undoElimination" class="secondary">Undo elimination for this pair</button>' : ''}
      <button id="savePlayer">Save changes</button><button id="deletePlayer" class="danger">Delete cast member</button>`);
    $('#editRole').addEventListener('change', (event) => {
      const role = event.target.value;
      $('#surpriseRate').hidden = role !== 'Surprise';
      $('#partnerField').hidden = !isAnyPairRole(role);
      if (isAnyPairRole(role)) $('#editPartner').innerHTML = `<option value="">No partner</option>${partnerOptions(activePairRole(role), players, partnerships, partner?.id)}`;
    });
    $('#savePlayer').addEventListener('click', async () => {
      const role = $('#editRole').value;
      const partnerId = isAnyPairRole(role) ? $('#editPartner').value : '';
      const { error: saveError } = await db.from('players').update({ role, custom_appearance_points: role === 'Surprise' ? Number($('#editRate').value) || null : null, image_path: player.image_path || imagePathFor(player.name) }).eq('id', id);
      if (saveError) return alert(`Couldn’t save ${player.name}: ${saveError.message}`);
      const pairingError = await replacePartnership(player, activePairRole(role), partnerId, partnerships);
      if (pairingError) return alert(`The cast member saved, but the partnership could not be saved: ${pairingError.message}`);
      $('#modal').close(); loadRoster();
    });
    $('#undoElimination')?.addEventListener('click', () => undoElimination(player, partner));
    $('#deletePlayer').addEventListener('click', async () => {
      if (!confirm(`Delete ${player.name}? This cannot be undone.`)) return;
      const pairingError = await replacePartnership(player, player.role, '', partnerships);
      if (pairingError) return alert(`Couldn’t remove the partnership: ${pairingError.message}`);
      const { error: deleteError } = await db.from('players').delete().eq('id', id);
      if (deleteError) return alert(`Couldn’t delete ${player.name}: ${deleteError.message}`);
      $('#modal').close(); loadRoster();
    });
  } catch (error) { alert(`Couldn’t open this cast member: ${error.message}`); }
}

async function openAddPlayer() {
  let pairingData;
  try { pairingData = await getPairingData(); } catch (error) { return alert(`Couldn’t prepare partnerships: ${error.message}`); }
  const { players, partnerships } = pairingData;
  openModal(`<h2>Add Cast Member</h2><p class="sub">Their image path is set automatically from their name.</p>
    <label>Name<input id="newName" autocomplete="off" required></label>
    <label>Role<select id="newRole">${roles.map((role) => `<option>${role}</option>`).join('')}</select></label>
    <label id="newSurpriseRate" hidden>Points per appearance<input id="newRate" type="number" min="0"></label>
    <label id="newPartnerField">Add partnership <span class="optional">(optional)</span><select id="newPartner"><option value="">No partner yet</option>${partnerOptions('Star', players, partnerships)}</select></label>
    <button id="createPlayer">Create cast member</button>`);
  $('#newRole').addEventListener('change', (event) => {
    const role = event.target.value;
    $('#newSurpriseRate').hidden = role !== 'Surprise';
    $('#newPartnerField').hidden = !isPairRole(role);
    if (isPairRole(role)) $('#newPartner').innerHTML = `<option value="">No partner yet</option>${partnerOptions(role, players, partnerships)}`;
  });
  $('#createPlayer').addEventListener('click', async () => {
    const name = $('#newName').value.trim();
    if (!name) return alert('Enter a cast member name first.');
    const role = $('#newRole').value;
    const { data: created, error } = await db.from('players').insert({ name, role, image_path: imagePathFor(name), custom_appearance_points: role === 'Surprise' ? Number($('#newRate').value) || null : null }).select().single();
    if (error) return alert(`Couldn’t create ${name}: ${error.message}`);
    const partnerId = isPairRole(role) ? $('#newPartner').value : '';
    const pairingError = await replacePartnership(created, role, partnerId, partnerships);
    if (pairingError) return alert(`${name} was created, but the partnership could not be saved: ${pairingError.message}`);
    $('#modal').close(); loadRoster();
  });
}

async function loadTeams() {
  const [{ data: teams, error: teamError }, { data: memberships, error: membershipError }, { data: players, error: playerError }] = await Promise.all([
    db.from('fantasy_teams').select('*').order('manager_name'),
    db.from('roster_history').select('player_id,fantasy_team_id,ends_week_id').is('ends_week_id', null),
    db.from('players').select('id,name,role').order('name'),
  ]);
  if (teamError || membershipError || playerError) {
    $('#teamResults').innerHTML = `<div class="card empty error">Couldn’t load teams: ${escapeHtml(teamError?.message || membershipError?.message || playerError?.message)}</div>`;
    return;
  }
  if (!teams.length) {
    $('#teamResults').innerHTML = '<div class="card empty">No fantasy teams yet.</div>';
    return;
  }
  const playerById = new Map(players.map((player) => [player.id, player]));
  $('#teamResults').innerHTML = teams.map((team) => {
    const roster = memberships.filter((member) => member.fantasy_team_id === team.id).map((member) => playerById.get(member.player_id)).filter(Boolean);
    return `<article class="card team-card"><p class="eyebrow">${escapeHtml(team.manager_name)}</p><h2>${escapeHtml(team.team_name || `${team.manager_name}'s Team`)}</h2>
      <p class="sub">${roster.length ? roster.map((player) => escapeHtml(player.name)).join(' · ') : 'No cast members assigned yet.'}</p>
      ${canEdit ? `<div class="team-actions"><button class="secondary" data-edit-team-id="${team.id}">Edit team</button><button data-team-id="${team.id}">Add Cast Members</button></div>` : ''}
    </article>`;
  }).join('');
  document.querySelectorAll('[data-team-id]').forEach((button) => button.addEventListener('click', () => openAssignCastMember(button.dataset.teamId)));
  document.querySelectorAll('[data-edit-team-id]').forEach((button) => button.addEventListener('click', () => openEditTeam(button.dataset.editTeamId)));
}

function openNewTeam() {
  openModal(`<h2>Add Fantasy Team</h2><p class="sub">Enter the manager's name. A team name is optional.</p>
    <label>Name<input id="newManagerName" autocomplete="off" required></label>
    <label>Team name <span class="optional">(optional)</span><input id="newTeamName" autocomplete="off"></label>
    <button id="createTeam">Create fantasy team</button>`);
  $('#createTeam').addEventListener('click', async () => {
    const managerName = $('#newManagerName').value.trim();
    const teamName = $('#newTeamName').value.trim();
    if (!managerName) return alert('Enter the manager name first.');
    const { error } = await db.from('fantasy_teams').insert({ manager_name: managerName, team_name: teamName || null });
    if (error) return alert(`Couldn’t create this team: ${error.message}`);
    $('#modal').close(); loadTeams();
  });
}

async function openAssignCastMember(teamId) {
  const [{ data: players, error: playerError }, { data: memberships, error: membershipError }, { data: team, error: teamError }] = await Promise.all([
    db.from('players').select('id,name,role').order('name'),
    db.from('roster_history').select('player_id').is('ends_week_id', null),
    db.from('fantasy_teams').select('manager_name,team_name').eq('id', teamId).single(),
  ]);
  const error = playerError || membershipError || teamError;
  if (error) return alert(`Couldn’t open available cast: ${error.message}`);
  const assigned = new Set(memberships.map((member) => member.player_id));
  const available = players.filter((player) => !assigned.has(player.id));
  const displayName = team.team_name || `${team.manager_name}'s Team`;
  openModal(`<h2>Add Cast Members</h2><p class="sub">Select one or more currently available cast members for ${escapeHtml(displayName)}.</p>
    ${available.length ? `<input id="castPickerSearch" placeholder="Search available cast" autocomplete="off"><div class="filter-tabs" id="pickerTabs"><button class="selected" data-picker-filter="all">All</button><button data-picker-filter="pros">Pros</button><button data-picker-filter="stars">Stars</button><button data-picker-filter="bonus">Bonus</button></div><div id="castPicker" class="cast-picker">${available.map((player) => `<label class="cast-choice" data-cast-name="${escapeHtml(player.name.toLowerCase())}" data-cast-category="${castCategory(player)}"><input type="checkbox" value="${player.id}"><span><b>${escapeHtml(player.name)}</b><small>${escapeHtml(player.role)}</small></span></label>`).join('')}</div><button id="assignCastMember">Add 0 cast members</button>` : '<p class="sub">Every cast member is already assigned to a fantasy team.</p>'}`);
  const updateSelection = () => {
    const count = document.querySelectorAll('#castPicker input:checked').length;
    $('#assignCastMember').textContent = `Add ${count} cast member${count === 1 ? '' : 's'}`;
  };
  let pickerFilter = 'all';
  const filterPicker = () => {
    const term = $('#castPickerSearch').value.trim().toLowerCase();
    document.querySelectorAll('.cast-choice').forEach((choice) => {
      choice.hidden = !choice.dataset.castName.includes(term) || (pickerFilter !== 'all' && choice.dataset.castCategory !== pickerFilter);
    });
  };
  $('#castPickerSearch')?.addEventListener('input', filterPicker);
  document.querySelectorAll('[data-picker-filter]').forEach((button) => button.addEventListener('click', () => {
    pickerFilter = button.dataset.pickerFilter;
    document.querySelectorAll('[data-picker-filter]').forEach((item) => item.classList.toggle('selected', item === button));
    filterPicker();
  }));
  document.querySelectorAll('#castPicker input').forEach((checkbox) => checkbox.addEventListener('change', updateSelection));
  $('#assignCastMember')?.addEventListener('click', async () => {
    const playerIds = [...document.querySelectorAll('#castPicker input:checked')].map((checkbox) => checkbox.value);
    if (!playerIds.length) return alert('Choose at least one cast member first.');
    const { error: assignError } = await db.from('roster_history').insert(playerIds.map((player_id) => ({ player_id, fantasy_team_id: teamId })));
    if (assignError) return alert(`Couldn’t add those cast members: ${assignError.message}`);
    $('#modal').close(); loadTeams();
  });
}

async function openEditTeam(teamId) {
  const { data: team, error } = await db.from('fantasy_teams').select('id,manager_name,team_name').eq('id', teamId).single();
  if (error) return alert(`Couldn’t open this team: ${error.message}`);
  openModal(`<h2>Edit Fantasy Team</h2><label>Name<input id="editManagerName" value="${escapeHtml(team.manager_name)}" required></label>
    <label>Team name <span class="optional">(optional)</span><input id="editTeamName" value="${escapeHtml(team.team_name || '')}"></label>
    <button id="saveTeam">Save changes</button>`);
  $('#saveTeam').addEventListener('click', async () => {
    const manager_name = $('#editManagerName').value.trim();
    const team_name = $('#editTeamName').value.trim();
    if (!manager_name) return alert('Enter the name first.');
    const { error: saveError } = await db.from('fantasy_teams').update({ manager_name, team_name: team_name || null }).eq('id', teamId);
    if (saveError) return alert(`Couldn’t save this team: ${saveError.message}`);
    $('#modal').close(); loadTeams();
  });
}

$('#rosterSearch').addEventListener('input', loadRoster);
document.querySelectorAll('[data-roster-filter]').forEach((button) => button.addEventListener('click', () => {
  rosterFilter = button.dataset.rosterFilter;
  document.querySelectorAll('[data-roster-filter]').forEach((item) => item.classList.toggle('selected', item === button));
  loadRoster();
}));
$('#newPlayer').addEventListener('click', openAddPlayer);
$('#newTeam').addEventListener('click', openNewTeam);
window.addEventListener('mirrorball-auth-change', async (event) => {
  canEdit = event.detail.signedIn;
  $('#newPlayer').hidden = !canEdit;
  $('#newTeam').hidden = !canEdit;
  loadRoster();
  loadTeams();
});
db.auth.getSession().then(({ data: { session } }) => {
  canEdit = Boolean(session);
  $('#newPlayer').hidden = !canEdit;
  $('#newTeam').hidden = !canEdit;
  loadRoster();
  loadTeams();
});
