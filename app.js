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
let selectedWeekId = null;
let standingsSnapshot = null;

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
  const [{ data: players, error: playerError }, { data: partnerships, error: pairingError }, { data: weeks, error: weekError }, { data: teams, error: teamError }] = await Promise.all([
    db.from('cast_members').select('*').order('name'),
    db.from('partnerships').select('id,star_id,pro_id,active,partnership_name').eq('active', true),
    db.from('weeks').select('id,number,label').order('number', { ascending: false }),
    db.from('fantasy_teams').select('id,manager_name,team_name'),
  ]);
  if (playerError || pairingError || weekError || teamError) throw new Error(playerError?.message || pairingError?.message || weekError?.message || teamError?.message);
  return { players, partnerships, weeks, teams };
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

async function replacePartnership(player, role, partnerId, partnerships, partnershipName = null) {
  const current = partnerships.find((item) => item.star_id === player.id || item.pro_id === player.id);
  const currentPartnerId = current && (current.star_id === player.id ? current.pro_id : current.star_id);
  if (currentPartnerId === (partnerId || null)) {
    if (!current || current.partnership_name === partnershipName) return null;
    const { error } = await db.from('partnerships').update({ partnership_name: partnershipName }).eq('id', current.id);
    return error;
  }
  const idsToClear = [player.id, partnerId].filter(Boolean);
  for (const id of idsToClear) {
    const { error } = await db.from('partnerships').delete().or(`star_id.eq.${id},pro_id.eq.${id}`);
    if (error) return error;
  }
  if (!partnerId) return null;
  const row = role === 'Star' ? { star_id: player.id, pro_id: partnerId, active: true, partnership_name: partnershipName } : { star_id: partnerId, pro_id: player.id, active: true, partnership_name: partnershipName };
  const { error } = await db.from('partnerships').insert(row);
  return error;
}

async function loadRoster() {
  const query = $('#rosterSearch').value.trim();
  let rosterData;
  try { rosterData = await getPairingData(); } catch (error) { return showRosterMessage(`Couldn’t load the cast: ${error.message}`, true); }
  const { players: allPlayers, partnerships, weeks, teams } = rosterData;
  const players = allPlayers.filter((player) => player.name.toLowerCase().includes(query.toLowerCase()) && (rosterFilter === 'all' || castCategory(player) === rosterFilter));
  if (!players.length) return showRosterMessage('No cast members yet. Add them manually.');
  $('#rosterResults').innerHTML = players.map((player) => `
    <div class="row"><img class="player-photo" style="object-position:${player.image_position ?? 50}% center" src="${player.image_path || imagePathFor(player.name)}" alt="">
      <span><b>${player.name}</b><small>${rosterDetail(player, partnerships, allPlayers, weeks, teams)}</small></span>
      ${canEdit ? `<button data-player-id="${player.id}">Edit</button>` : ''}
    </div>`).join('');
  document.querySelectorAll('[data-player-id]').forEach((button) => button.addEventListener('click', () => editPlayer(button.dataset.playerId)));
}

function rosterDetail(player, partnerships, players, weeks, teams) {
  const partner = partnerFor(player, partnerships, players);
  const partnership = partnerships.find((item) => item.star_id === player.id || item.pro_id === player.id);
  const base = player.role === 'Surprise' && player.custom_appearance_points ? `Surprise · +${player.custom_appearance_points}` : player.role;
  const fantasyTeam = teams.find((team) => team.id === player.fantasy_team_id);
  const teamText = fantasyTeam ? ` · ${fantasyTeam.team_name || `${fantasyTeam.manager_name}'s Team`}` : '';
  if (!isAnyPairRole(player.role)) return `${base}${teamText}`;
  const partnerText = partner ? `${partner.name}${teamText}` : '<strong class="missing">No partner assigned</strong>';
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
    openModal(`<div class="cast-modal-heading"><img id="editPhotoPreview" class="cast-modal-photo" style="object-position:${player.image_position ?? 50}% center" src="${player.image_path || imagePathFor(player.name)}" alt=""><div><p class="eyebrow">Cast Member</p><h2>${player.name}</h2><p class="sub">Update cast details, partnership, or portrait framing.</p></div></div>
      <label>Role<select id="editRole">${roles.map((role) => `<option ${role === player.role ? 'selected' : ''}>${role}</option>`).join('')}</select></label>
      <label id="surpriseRate" ${player.role === 'Surprise' ? '' : 'hidden'}>Points per appearance<input id="editRate" type="number" min="0" value="${player.custom_appearance_points ?? ''}"></label>
      <label id="partnerField" ${isAnyPairRole(player.role) ? '' : 'hidden'}>Partner<select id="editPartner"><option value="">No partner</option>${partnerOptions(activePairRole(player.role), players, partnerships, partner?.id)}</select></label>
      <label id="partnershipNameField" ${partner ? '' : 'hidden'}>Partnership name <span class="optional">(optional)</span><input id="partnershipName" value="${escapeHtml(partnership?.partnership_name || '')}" placeholder="e.g., Team Sparkle"></label>
      <label>Portrait position<input id="imagePosition" type="range" min="0" max="100" value="${player.image_position ?? 50}"><span class="range-note">Move left or right to center the image.</span></label>
      <div class="modal-actions"><button id="savePlayer">Save changes</button><button id="deletePlayer" class="danger">Delete cast member</button></div>`);
    $('#editRole').addEventListener('change', (event) => {
      const role = event.target.value;
      $('#surpriseRate').hidden = role !== 'Surprise';
      $('#partnerField').hidden = !isAnyPairRole(role);
      if (isAnyPairRole(role)) $('#editPartner').innerHTML = `<option value="">No partner</option>${partnerOptions(activePairRole(role), players, partnerships, partner?.id)}`;
    });
    $('#editPartner').addEventListener('change', (event) => { $('#partnershipNameField').hidden = !event.target.value; });
    $('#imagePosition').addEventListener('input', (event) => { $('#editPhotoPreview').style.objectPosition = `${event.target.value}% center`; });
    $('#savePlayer').addEventListener('click', async () => {
      const role = $('#editRole').value;
      const partnerId = isAnyPairRole(role) ? $('#editPartner').value : '';
      const partnershipName = $('#editPartner').value ? $('#partnershipName').value.trim() || null : null;
      const { error: saveError } = await db.from('cast_members').update({ role, custom_appearance_points: role === 'Surprise' ? Number($('#editRate').value) || null : null, image_path: player.image_path || imagePathFor(player.name), image_position: Number($('#imagePosition').value) }).eq('id', id);
      if (saveError) return alert(`Couldn’t save ${player.name}: ${saveError.message}`);
      const pairingError = await replacePartnership(player, activePairRole(role), partnerId, partnerships, partnershipName);
      if (pairingError) return alert(`The cast member saved, but the partnership could not be saved: ${pairingError.message}`);
      $('#modal').close(); loadRoster(); loadTeams(); loadStandings();
    });
    $('#deletePlayer').addEventListener('click', async () => {
      if (!confirm(`Delete ${player.name}? This cannot be undone.`)) return;
      const pairingError = await replacePartnership(player, player.role, '', partnerships);
      if (pairingError) return alert(`Couldn’t remove the partnership: ${pairingError.message}`);
      const { error: deleteError } = await db.from('cast_members').delete().eq('id', id);
      if (deleteError) return alert(`Couldn’t delete ${player.name}: ${deleteError.message}`);
      $('#modal').close(); loadRoster(); loadTeams(); loadStandings();
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
    const { data: created, error } = await db.from('cast_members').insert({ name, role, image_path: imagePathFor(name), custom_appearance_points: role === 'Surprise' ? Number($('#newRate').value) || null : null }).select().single();
    if (error) return alert(`Couldn’t create ${name}: ${error.message}`);
    const partnerId = isPairRole(role) ? $('#newPartner').value : '';
    const pairingError = await replacePartnership(created, role, partnerId, partnerships);
    if (pairingError) return alert(`${name} was created, but the partnership could not be saved: ${pairingError.message}`);
    $('#modal').close(); loadRoster(); loadTeams(); loadStandings();
  });
}

async function loadTeams() {
  const [{ data: teams, error: teamError }, { data: castMembers, error: castError }] = await Promise.all([
    db.from('fantasy_teams').select('*').order('manager_name'),
    db.from('cast_members').select('id,name,role,image_path,image_position,fantasy_team_id').order('name'),
  ]);
  if (teamError || castError) {
    $('#teamResults').innerHTML = `<div class="card empty error">Couldn’t load teams: ${escapeHtml(teamError?.message || castError?.message)}</div>`;
    return;
  }
  const availableCount = castMembers.filter((member) => !member.fantasy_team_id).length;
  $('#newTeam').hidden = !canEdit || !availableCount;
  if (!teams.length) {
    $('#teamResults').innerHTML = '<div class="card empty">No fantasy teams yet.</div>';
    return;
  }
  $('#teamResults').innerHTML = teams.map((team) => {
    const roster = castMembers.filter((member) => member.fantasy_team_id === team.id);
    const displayName = team.team_name || `${team.manager_name}'s Team`;
    return `<article class="card team-card" data-team-card-id="${team.id}" data-team-detail="${team.id}" tabindex="0" role="button" aria-label="View ${escapeHtml(displayName)} cast roster"><div class="team-card-head"><div><p class="eyebrow">${escapeHtml(team.manager_name)}</p><h2>${escapeHtml(displayName)}</h2></div>${canEdit ? `<button class="secondary team-edit-button" data-edit-team-id="${team.id}">Edit</button>` : ''}</div>
      <p class="team-count">${roster.length} cast member${roster.length === 1 ? '' : 's'}</p>
      ${roster.length ? `<ul class="team-roster">${roster.map((member) => `<li><span>${escapeHtml(member.name)}</span><small>${escapeHtml(member.role)}</small></li>`).join('')}</ul>` : '<p class="sub">No cast members assigned yet.</p>'}
      ${canEdit && availableCount ? `<div class="team-actions"><button data-team-id="${team.id}">Add Cast Members</button></div>` : ''}
    </article>`;
  }).join('');
  document.querySelectorAll('[data-team-id]').forEach((button) => button.addEventListener('click', (event) => { event.stopPropagation(); openAssignCastMember(button.dataset.teamId); }));
  document.querySelectorAll('[data-edit-team-id]').forEach((button) => button.addEventListener('click', (event) => { event.stopPropagation(); editTeamCard(button.dataset.editTeamId); }));
  document.querySelectorAll('[data-team-detail]').forEach((card) => {
    const open = () => { if (!card.classList.contains('editing')) openTeamDetail(card.dataset.teamDetail); };
    card.addEventListener('click', open);
    card.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

async function openTeamDetail(teamId) {
  const [{ data: team, error: teamError }, { data: roster, error: rosterError }] = await Promise.all([
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('id', teamId).single(),
    db.from('cast_members').select('id,name,role,image_path,image_position').eq('fantasy_team_id', teamId).order('name'),
  ]);
  const error = teamError || rosterError;
  if (error) return alert(`Couldn’t load this team: ${error.message}`);
  const displayName = team.team_name || `${team.manager_name}'s Team`;
  openModal(`<div class="team-detail-head"><div><p class="eyebrow">${escapeHtml(team.manager_name)}</p><h2>${escapeHtml(displayName)}</h2><p class="sub">${roster.length} cast member${roster.length === 1 ? '' : 's'} on the current roster</p></div></div>
    ${roster.length ? `<div class="team-detail-grid">${roster.map((member) => `<article class="team-detail-member"><img src="${member.image_path || imagePathFor(member.name)}" style="object-position:${member.image_position ?? 50}% center" alt=""><div><b>${escapeHtml(member.name)}</b><span>${escapeHtml(member.role)}</span></div></article>`).join('')}</div>` : '<p class="sub">No cast members assigned yet.</p>'}`);
}

async function editTeamCard(teamId) {
  const [{ data: team, error: teamError }, { data: roster, error: rosterError }] = await Promise.all([
    db.from('fantasy_teams').select('id,manager_name,team_name').eq('id', teamId).single(),
    db.from('cast_members').select('id,name,role').eq('fantasy_team_id', teamId).order('name'),
  ]);
  const error = teamError || rosterError;
  if (error) return alert(`Couldn’t edit this team: ${error.message}`);
  const card = document.querySelector(`[data-team-card-id="${teamId}"]`);
  if (!card) return;
  card.classList.add('editing');
  card.innerHTML = `<div class="team-card-head"><div class="team-edit-fields"><label>Name<input id="teamManager-${teamId}" value="${escapeHtml(team.manager_name)}"></label><label>Team name <span class="optional">(optional)</span><input id="teamName-${teamId}" value="${escapeHtml(team.team_name || '')}"></label></div></div><div class="team-edit-buttons"><button class="secondary" data-cancel-team-id="${teamId}">Cancel</button><button data-save-team-id="${teamId}">Save</button></div></div>
    <p class="team-count">${roster.length} cast member${roster.length === 1 ? '' : 's'}</p>
    ${roster.length ? `<ul class="team-roster">${roster.map((member) => `<li><span>${escapeHtml(member.name)}</span><small>${escapeHtml(member.role)}</small><button class="remove-member" data-remove-team-cast-id="${member.id}">Remove</button></li>`).join('')}</ul>` : '<p class="sub">No cast members assigned yet.</p>'}`;
  document.querySelector(`[data-cancel-team-id="${teamId}"]`).addEventListener('click', loadTeams);
  document.querySelector(`[data-save-team-id="${teamId}"]`).addEventListener('click', async () => {
    const manager_name = $(`#teamManager-${teamId}`).value.trim();
    const team_name = $(`#teamName-${teamId}`).value.trim();
    if (!manager_name) return alert('Enter the name first.');
    const { error: saveError } = await db.from('fantasy_teams').update({ manager_name, team_name: team_name || null }).eq('id', teamId);
    if (saveError) return alert(`Couldn’t save this team: ${saveError.message}`);
    loadTeams(); loadStandings();
  });
  document.querySelectorAll('[data-remove-team-cast-id]').forEach((button) => button.addEventListener('click', async () => {
    const member = roster.find((item) => item.id === button.dataset.removeTeamCastId);
    if (!confirm(`Remove ${member.name} from this fantasy team?`)) return;
    const { error: removeError } = await db.from('cast_members').update({ fantasy_team_id: null }).eq('id', member.id);
    if (removeError) return alert(`Couldn’t remove ${member.name}: ${removeError.message}`);
    editTeamCard(teamId); loadStandings();
  }));
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
    $('#modal').close(); loadTeams(); loadStandings();
  });
}

async function openAssignCastMember(teamId) {
  const [{ data: castMembers, error: castError }, { data: team, error: teamError }] = await Promise.all([
    db.from('cast_members').select('id,name,role,fantasy_team_id').order('name'),
    db.from('fantasy_teams').select('manager_name,team_name').eq('id', teamId).single(),
  ]);
  const error = castError || teamError;
  if (error) return alert(`Couldn’t open available cast: ${error.message}`);
  const available = castMembers.filter((member) => !member.fantasy_team_id);
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
    const { error: assignError } = await db.from('cast_members').update({ fantasy_team_id: teamId }).in('id', playerIds);
    if (assignError) return alert(`Couldn’t add those cast members: ${assignError.message}`);
    $('#modal').close(); loadTeams(); loadStandings();
  });
}

function weekTitle(week) {
  return week.title || (week.theme ? `${week.theme} Week` : `Week ${week.number}`);
}

function roleForWeek(member, week, weeks) {
  if (!member?.role?.startsWith('Eliminated')) return member?.role || '';
  const eliminatedWeek = weeks.find((item) => item.id === member.eliminated_week_id);
  if (week && eliminatedWeek && week.number <= eliminatedWeek.number) return member.role.replace('Eliminated ', '');
  return member.role;
}

function appearanceValue(member, roleMap, week, weeks) {
  if (!member) return 0;
  const role = roleForWeek(member, week, weeks);
  if (role === 'Surprise') return Number(member.custom_appearance_points) || 0;
  return Number(roleMap.get(role)?.appearance_points) || 0;
}

async function loadStandings() {
  const [teamsResult, membersResult, rolesResult, partnershipsResult, weeksResult, dancesResult, scoresResult, appearancesResult] = await Promise.all([
    db.from('fantasy_teams').select('id,manager_name,team_name').order('manager_name'),
    db.from('cast_members').select('id,name,role,custom_appearance_points,fantasy_team_id,eliminated_week_id').order('name'),
    db.from('roles').select('name,appearance_points'),
    db.from('partnerships').select('id,star_id,pro_id').eq('active', true),
    db.from('weeks').select('id,number,title,theme').order('number'),
    db.from('dances').select('id,kind,partnership_id,week_id'),
    db.from('dance_judge_scores').select('dance_id,score'),
    db.from('dance_appearances').select('dance_id,cast_member_id'),
  ]);
  const error = [teamsResult, membersResult, rolesResult, partnershipsResult, weeksResult, dancesResult, scoresResult, appearancesResult].find((result) => result.error)?.error;
  if (error) {
    $('#standingsContent').innerHTML = `<div class="card empty error">Couldn’t load standings: ${escapeHtml(error.message)}</div>`;
    return;
  }
  const data = { teams: teamsResult.data, members: membersResult.data, roles: rolesResult.data, partnerships: partnershipsResult.data, weeks: weeksResult.data, dances: dancesResult.data, scores: scoresResult.data, appearances: appearancesResult.data };
  const { teams, members, weeks, memberPoints, weekMemberPoints } = calculateLeaguePoints(data);
  standingsSnapshot = { ...data, memberPoints, weekMemberPoints };
  const teamRows = teams.map((team) => {
    const roster = members.filter((member) => member.fantasy_team_id === team.id);
    const total = roster.reduce((sum, member) => sum + (memberPoints.get(member.id) || 0), 0);
    return { team, roster, total };
  }).sort((a, b) => b.total - a.total || (a.team.team_name || a.team.manager_name).localeCompare(b.team.team_name || b.team.manager_name));
  const latestWeek = weeksResult.data.at(-1);
  $('#standingsSubtitle').textContent = latestWeek ? `Through ${weekTitle(latestWeek)} · current fantasy-team totals` : 'Current fantasy-team totals.';
  if (!teamRows.length) {
    $('#standingsContent').innerHTML = '<div class="card empty">No fantasy teams yet.</div>';
    return;
  }
  const leaderTotal = teamRows[0].total;
  const isFirstPlaceTie = teamRows.filter((row) => row.total === leaderTotal).length > 1;
  $('#standingsContent').innerHTML = `<div class="standings-grid">${teamRows.map((row, index) => {
    const contributors = [...row.roster].sort((a, b) => (memberPoints.get(b.id) || 0) - (memberPoints.get(a.id) || 0) || a.name.localeCompare(b.name));
    const tiedLeader = isFirstPlaceTie && row.total === leaderTotal;
    return `<article class="card standing-card ${tiedLeader || index === 0 ? 'leader' : ''} ${tiedLeader ? 'tied-leader' : ''}" data-standing-team="${row.team.id}" tabindex="0" role="button" aria-label="View ${escapeHtml(row.team.team_name || `${row.team.manager_name}'s Team`)} score breakdown"><div class="standing-rank">${tiedLeader ? 'T-1' : index + 1}</div><div class="standing-main"><p class="eyebrow">${escapeHtml(row.team.manager_name)}</p><h2>${escapeHtml(row.team.team_name || `${row.team.manager_name}'s Team`)}</h2>${tiedLeader ? '<p class="tie-note">Tied for first</p>' : ''}<p class="standing-roster">${row.roster.length} cast member${row.roster.length === 1 ? '' : 's'}</p><div class="standing-contributors">${contributors.slice(0, 4).map((member) => `<span>${escapeHtml(member.name)} <b>${memberPoints.get(member.id) || 0}</b></span>`).join('') || '<span>No cast assigned</span>'}${contributors.length > 4 ? `<span>+${contributors.length - 4} more</span>` : ''}</div></div><div class="standing-total"><strong>${row.total}</strong><span>points</span></div></article>`;
  }).join('')}</div>`;
  document.querySelectorAll('[data-standing-team]').forEach((card) => {
    const open = () => openStandingBreakdown(card.dataset.standingTeam);
    card.addEventListener('click', open);
    card.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

function calculateLeaguePoints(data) {
  const memberById = new Map(data.members.map((member) => [member.id, member]));
  const roleMap = new Map(data.roles.map((role) => [role.name, role]));
  const partnershipById = new Map(data.partnerships.map((partnership) => [partnership.id, partnership]));
  const danceById = new Map(data.dances.map((dance) => [dance.id, dance]));
  const weekById = new Map(data.weeks.map((week) => [week.id, week]));
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
    if (dance) add(member?.id, dance.week_id, 'appearances', appearanceValue(member, roleMap, weekById.get(dance.week_id), data.weeks));
  });
  return { teams: data.teams, members: data.members, weeks: data.weeks, memberPoints, weekMemberPoints };
}

function openStandingBreakdown(teamId) {
  if (!standingsSnapshot) return;
  const { teams, members, weeks, weekMemberPoints } = standingsSnapshot;
  const team = teams.find((item) => item.id === teamId);
  const roster = members.filter((member) => member.fantasy_team_id === teamId);
  if (!team) return;
  openModal(`<div id="standingBreakdown"></div>`);
  const draw = (weekId = 'all') => {
    const currentWeeks = weekId === 'all' ? weeks : weeks.filter((week) => week.id === weekId);
    const pointsFor = (member) => currentWeeks.reduce((total, week) => {
      const entry = weekMemberPoints.get(week.id)?.get(member.id);
      return total + (entry?.official || 0) + (entry?.appearances || 0);
    }, 0);
    const rows = [...roster].map((member) => {
      const sources = currentWeeks.reduce((result, week) => { const entry = weekMemberPoints.get(week.id)?.get(member.id); result.official += entry?.official || 0; result.appearances += entry?.appearances || 0; result.appearanceCount += entry?.appearanceCount || 0; result.appearanceRates.push(...(entry?.appearanceRates || [])); return result; }, { official: 0, appearances: 0, appearanceCount: 0, appearanceRates: [] });
      const status = currentWeeks.length === 1 ? roleForWeek(member, currentWeeks[0], weeks) : member.role;
      return { member, status, ...sources, total: pointsFor(member) };
    }).sort((a, b) => b.total - a.total || a.member.name.localeCompare(b.member.name));
    const total = rows.reduce((sum, row) => sum + row.total, 0);
    const appearanceLabel = (row) => { if (!row.appearanceCount) return '—'; const rates = [...new Set(row.appearanceRates)]; const rateText = rates.length === 1 ? `+${rates[0]} each` : rates.map((rate) => `+${rate}`).join(' / '); return `${row.appearanceCount} dance${row.appearanceCount === 1 ? '' : 's'} · ${rateText}`; };
    $('#standingBreakdown').innerHTML = `<div class="breakdown-head"><div><p class="eyebrow">${escapeHtml(team.manager_name)}</p><h2>${escapeHtml(team.team_name || `${team.manager_name}'s Team`)}</h2><p class="sub">Where this team’s fantasy points came from.</p></div><div class="breakdown-total"><strong>${total}</strong><span>points</span></div></div><label class="breakdown-week">View<select id="standingWeek"> <option value="all">All weeks</option>${weeks.map((week) => `<option value="${week.id}" ${week.id === weekId ? 'selected' : ''}>${escapeHtml(weekTitle(week))}</option>`).join('')}</select></label><div class="breakdown-table"><div class="breakdown-row breakdown-labels"><span>Cast member</span><span>Judges</span><span>Appearances</span><span>Total</span></div>${rows.map((row) => `<div class="breakdown-row"><span><b>${escapeHtml(row.member.name)}</b><small>${escapeHtml(row.status)}</small></span><span>${row.official}</span><span class="appearance-detail">${escapeHtml(appearanceLabel(row))}<small>${row.appearances ? `${row.appearances} points` : ''}</small></span><strong>${row.total}</strong></div>`).join('') || '<p class="sub">No cast members assigned.</p>'}</div>`;
    $('#standingWeek').addEventListener('change', (event) => draw(event.target.value));
  };
  draw();
}

async function loadScoreDesk() {
  const { data: weeks, error } = await db.from('weeks').select('id,number,label,theme,title,guest_judge_name,double_elimination,is_finale').order('number');
  if (error) return $('#scoreDeskContent').innerHTML = `<div class="card empty error">Couldn’t load weeks: ${escapeHtml(error.message)}</div>`;
  if (!weeks.length) {
    $('#weekTabs').innerHTML = '';
    $('#scoreDeskContent').innerHTML = '<div class="card empty">No weeks yet. Add Week 1 when you are ready to score.</div>';
    return;
  }
  if (!weeks.some((week) => week.id === selectedWeekId)) selectedWeekId = weeks[weeks.length - 1].id;
  $('#weekTabs').innerHTML = weeks.map((week) => `<button class="${week.id === selectedWeekId ? 'selected' : ''}" data-score-week="${week.id}">Week ${week.number}</button>`).join('');
  document.querySelectorAll('[data-score-week]').forEach((button) => button.addEventListener('click', () => { selectedWeekId = button.dataset.scoreWeek; loadScoreDesk(); }));
  const week = weeks.find((item) => item.id === selectedWeekId);
  const [{ data: dances, error: danceError }, { data: judgeScores, error: judgeError }, { data: appearances, error: appearanceError }] = await Promise.all([
    db.from('dances').select('id,kind,partnership_id,name,dance_type,song,sort_order').eq('week_id', week.id).order('sort_order'),
    db.from('dance_judge_scores').select('dance_id,judge_name,score'),
    db.from('dance_appearances').select('dance_id,cast_member_id'),
  ]);
  if (danceError || judgeError || appearanceError) return $('#scoreDeskContent').innerHTML = `<div class="card empty error">Couldn’t load dances: ${escapeHtml(danceError?.message || judgeError?.message || appearanceError?.message)}</div>`;
  const pairData = await getPairingData().catch(() => ({ players: [], partnerships: [] }));
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
  $('#scoreDeskContent').innerHTML = `<div class="score-week-head card"><div><p class="eyebrow">Week ${week.number}</p><h2>${escapeHtml(weekTitle(week))}</h2><p class="sub">${week.guest_judge_name ? `Guest judge: ${escapeHtml(week.guest_judge_name)} · ` : ''}${week.is_finale ? 'No elimination' : (week.double_elimination ? 'Double elimination' : 'Standard elimination')}</p></div><div class="week-summary"><span>${competitiveCount} competitive</span><span>${performanceCount} performances</span></div>${canEdit ? '<div class="score-week-actions"><button class="secondary" id="editWeek">Edit Week</button><button id="newDance">Add Dance</button></div>' : ''}</div>
    <div class="dance-list">${dances.length ? dances.map((dance, index) => { const scores = judgeScores.filter((score) => score.dance_id === dance.id); const details = [dance.dance_type, dance.song].filter(Boolean).map(escapeHtml); return `<article class="card dance-row dance-${dance.kind}" data-dance-detail="${dance.id}" tabindex="0" role="button" aria-label="View details for ${escapeHtml(labelForDance(dance, index))}"><div class="dance-card-top"><div><p class="eyebrow">${dance.kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h3>${escapeHtml(labelForDance(dance, index))}</h3></div>${canEdit ? `<button class="secondary" data-edit-dance="${dance.id}">Edit</button>` : ''}</div>${dance.kind === 'competitive' ? `<div class="dance-details"><span>${details[0] || 'Dance type not set'}</span>${details[1] ? `<span>${details[1]}</span>` : ''}</div><div class="judge-paddles" aria-label="Judge scores">${scores.map((score) => `<img src="Images/Judges Scores/${score.score}.png" alt="${escapeHtml(score.judge_name)}: ${score.score}">`).join('')}</div>` : ''}${appearanceSummary(dance.id)}</article>`; }).join('') : '<div class="card empty">No dances entered for this week.</div>'}</div>`;
  $('#newDance')?.addEventListener('click', () => openNewDance(week, dances.length));
  $('#editWeek')?.addEventListener('click', () => openEditWeek(week));
  document.querySelectorAll('[data-edit-dance]').forEach((button) => {
    const dance = dances.find((item) => item.id === button.dataset.editDance);
    button.addEventListener('click', (event) => { event.stopPropagation(); openEditDance(week, dance, dances.indexOf(dance)); });
  });
  document.querySelectorAll('[data-dance-detail]').forEach((tile) => {
    const dance = dances.find((item) => item.id === tile.dataset.danceDetail);
    const open = () => openDanceDetail(week, dance, dances.indexOf(dance), pairData, judgeScores.filter((score) => score.dance_id === dance.id), dancers(dance.id));
    tile.addEventListener('click', open);
    tile.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

function openDanceDetail(week, dance, index, pairData, scores, cast) {
  const title = dance.kind === 'competitive' ? (() => { const pairing = pairData.partnerships.find((item) => item.id === dance.partnership_id); const star = pairData.players.find((player) => player.id === pairing?.star_id); const pro = pairData.players.find((player) => player.id === pairing?.pro_id); return star && pro ? `${star.name} & ${pro.name}` : `Competitive Dance ${index + 1}`; })() : dance.name || `Week ${week.number} Dance ${index + 1}`;
  const pairing = pairData.partnerships.find((item) => item.id === dance.partnership_id);
  const star = pairData.players.find((player) => player.id === pairing?.star_id);
  const pro = pairData.players.find((player) => player.id === pairing?.pro_id);
  const displayRole = (member) => roleForWeek(member, week, pairData.weeks || [week]);
  openModal(`<div class="dance-detail-head"><p class="eyebrow">${dance.kind === 'competitive' ? 'Competitive dance' : 'Performance'}</p><h2>${escapeHtml(title)}</h2>${dance.kind === 'competitive' ? `<p class="sub">${escapeHtml(dance.dance_type || 'Dance type not set')}${dance.song ? ` · ${escapeHtml(dance.song)}` : ''}</p>` : ''}</div>${dance.kind === 'competitive' ? `<section class="detail-section"><h3>Judges’ scores</h3><div class="detail-judges">${scores.map((score) => `<div><img src="Images/Judges Scores/${score.score}.png" alt="${escapeHtml(score.judge_name)}: ${score.score}"><span>${escapeHtml(score.judge_name)}</span></div>`).join('') || '<p class="sub">No scores entered.</p>'}</div></section><section class="detail-section"><h3>Competing couple</h3><div class="full-cast-list">${[star, pro].filter(Boolean).map((member) => `<div><b>${escapeHtml(member.name)}</b><span>${escapeHtml(displayRole(member))}</span></div>`).join('')}</div></section>` : ''}<section class="detail-section"><h3>${dance.kind === 'competitive' ? 'Additional cast' : 'Cast'}</h3>${cast.length ? `<div class="full-cast-list">${cast.map((member) => `<div><b>${escapeHtml(member.name)}</b><span>${escapeHtml(displayRole(member))}</span></div>`).join('')}</div>` : '<p class="sub">No cast appearances were recorded for this dance.</p>'}</section>`);
}

async function openNewWeek() {
  const { data: existing, error } = await db.from('weeks').select('number').order('number', { ascending: false }).limit(1);
  if (error) return alert(`Couldn’t prepare a new week: ${error.message}`);
  const number = (existing[0]?.number || 0) + 1;
  openModal(`<h2>Add Week ${number}</h2><label>Theme <span class="optional">(optional)</span><input id="weekTheme" autocomplete="off"></label><label>Week title <span class="optional">(optional)</span><input id="weekTitle" placeholder="${number === 1 ? 'Week 1' : `Week ${number}`}" autocomplete="off"></label><label class="check-label"><input id="guestJudgeEnabled" type="checkbox"> Guest judge</label><label id="guestJudgeField" hidden>Guest judge name<input id="guestJudgeName" autocomplete="off"></label><label class="check-label"><input id="doubleElimination" type="checkbox"> Double elimination</label><label class="check-label"><input id="isFinale" type="checkbox"> No elimination</label><div class="modal-actions"><button id="createWeek">Create Week ${number}</button></div>`);
  let titleTouched = false;
  $('#weekTitle').addEventListener('input', () => { titleTouched = true; });
  $('#weekTheme').addEventListener('input', (event) => { if (!titleTouched) $('#weekTitle').value = event.target.value.trim() ? `${event.target.value.trim()} Week` : `Week ${number}`; });
  $('#guestJudgeEnabled').addEventListener('change', (event) => { $('#guestJudgeField').hidden = !event.target.checked; });
  $('#createWeek').addEventListener('click', async () => {
    const theme = $('#weekTheme').value.trim();
    const title = $('#weekTitle').value.trim() || (theme ? `${theme} Week` : `Week ${number}`);
    const guest_judge_name = $('#guestJudgeEnabled').checked ? $('#guestJudgeName').value.trim() || null : null;
    if ($('#guestJudgeEnabled').checked && !guest_judge_name) return alert('Enter the guest judge’s name.');
    const { data: week, error: createError } = await db.from('weeks').insert({ number, theme: theme || null, title, guest_judge_name, double_elimination: $('#doubleElimination').checked, is_finale: $('#isFinale').checked }).select().single();
    if (createError) return alert(`Couldn’t create Week ${number}: ${createError.message}`);
    selectedWeekId = week.id; $('#modal').close(); loadScoreDesk();
  });
}

async function openEditWeek(week) {
  const { players, partnerships } = await getPairingData();
  const pairs = partnerships.filter((pairing) => { const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id); return star && pro && (star.role === 'Star' || star.eliminated_week_id === week.id) && (pro.role === 'Pro' || pro.eliminated_week_id === week.id); });
  const previouslyEliminated = pairs.filter((pairing) => { const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id); return star.eliminated_week_id === week.id || pro.eliminated_week_id === week.id; }).map((pairing) => pairing.id);
  const pairOptions = (selectedId = '') => `<option value="">No couple selected</option>${pairs.map((pairing) => { const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id); return `<option value="${pairing.id}" ${pairing.id === selectedId ? 'selected' : ''}>${escapeHtml(star.name)} & ${escapeHtml(pro.name)}</option>`; }).join('')}`;
  openModal(`<h2>Edit Week ${week.number}</h2><label>Theme <span class="optional">(optional)</span><input id="weekTheme" value="${escapeHtml(week.theme || '')}"></label><label>Week title <span class="optional">(optional)</span><input id="weekTitle" value="${escapeHtml(week.title || '')}" placeholder="${escapeHtml(weekTitle(week))}"></label><label class="check-label"><input id="guestJudgeEnabled" type="checkbox" ${week.guest_judge_name ? 'checked' : ''}> Guest judge</label><label id="guestJudgeField" ${week.guest_judge_name ? '' : 'hidden'}>Guest judge name<input id="guestJudgeName" value="${escapeHtml(week.guest_judge_name || '')}"></label><label class="check-label"><input id="doubleElimination" type="checkbox" ${week.double_elimination ? 'checked' : ''}> Double elimination</label><label class="check-label"><input id="isFinale" type="checkbox" ${week.is_finale ? 'checked' : ''}> No elimination</label><div id="weekEliminations" ${week.is_finale ? 'hidden' : ''}><h3>Eliminated couple${week.double_elimination ? 's' : ''}</h3><p class="sub">Choose the couple eliminated after this week.</p><div class="elimination-selects"><label>First elimination<select id="firstEliminatedPair">${pairOptions(previouslyEliminated[0])}</select></label><label id="secondEliminationField" ${week.double_elimination ? '' : 'hidden'}>Second elimination<select id="secondEliminatedPair">${pairOptions(previouslyEliminated[1])}</select></label></div></div><div class="modal-actions"><button id="saveWeek">Save changes</button></div>`);
  $('#guestJudgeEnabled').addEventListener('change', (event) => { $('#guestJudgeField').hidden = !event.target.checked; });
  $('#isFinale').addEventListener('change', (event) => { $('#weekEliminations').hidden = event.target.checked; });
  $('#doubleElimination').addEventListener('change', (event) => { $('#secondEliminationField').hidden = !event.target.checked; });
  $('#saveWeek').addEventListener('click', async () => {
    const theme = $('#weekTheme').value.trim(); const title = $('#weekTitle').value.trim() || (theme ? `${theme} Week` : `Week ${week.number}`); const guest_judge_name = $('#guestJudgeEnabled').checked ? $('#guestJudgeName').value.trim() || null : null;
    if ($('#guestJudgeEnabled').checked && !guest_judge_name) return alert('Enter the guest judge’s name.');
    const is_finale = $('#isFinale').checked;
    const { error } = await db.from('weeks').update({ theme: theme || null, title, guest_judge_name, double_elimination: $('#doubleElimination').checked, is_finale }).eq('id', week.id);
    if (error) return alert(`Couldn’t save Week ${week.number}: ${error.message}`);
    const selected = new Set(is_finale ? [] : [$('#firstEliminatedPair').value, $('#doubleElimination').checked ? $('#secondEliminatedPair').value : ''].filter(Boolean));
    if (!is_finale && $('#doubleElimination').checked && selected.size === 1 && $('#firstEliminatedPair').value && $('#secondEliminatedPair').value) return alert('Choose two different couples for a double elimination.');
    for (const pairing of pairs) {
      const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id);
      if (selected.has(pairing.id)) {
        const [starUpdate, proUpdate] = await Promise.all([
          db.from('cast_members').update({ role: 'Eliminated Star', eliminated_week_id: week.id }).eq('id', star.id),
          db.from('cast_members').update({ role: 'Eliminated Pro', eliminated_week_id: week.id }).eq('id', pro.id),
        ]);
        if (starUpdate.error || proUpdate.error) return alert(`Week saved, but ${star.name} and ${pro.name} could not be marked eliminated: ${(starUpdate.error || proUpdate.error).message}`);
      } else if (star.eliminated_week_id === week.id || pro.eliminated_week_id === week.id) {
        const [starUpdate, proUpdate] = await Promise.all([
          db.from('cast_members').update({ role: 'Star', eliminated_week_id: null }).eq('id', star.id),
          db.from('cast_members').update({ role: 'Pro', eliminated_week_id: null }).eq('id', pro.id),
        ]);
        if (starUpdate.error || proUpdate.error) return alert(`Week saved, but ${star.name} and ${pro.name} could not be restored: ${(starUpdate.error || proUpdate.error).message}`);
      }
    }
    $('#modal').close(); loadScoreDesk(); loadRoster(); loadStandings();
  });
}

async function openNewDance(week, danceCount, existingDance = null, existingScores = [], existingAppearanceIds = []) {
  const { players, partnerships } = await getPairingData();
  const activePairs = partnerships.filter((pairing) => {
    const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id);
    return star?.role === 'Star' && pro?.role === 'Pro';
  });
  const { data: scoredDances, error: scoredDancesError } = await db.from('dances').select('partnership_id').eq('week_id', week.id).eq('kind', 'competitive');
  if (scoredDancesError) return alert(`Couldn’t prepare this dance: ${scoredDancesError.message}`);
  const usedPairIds = new Set((scoredDances || []).map((dance) => dance.partnership_id).filter((id) => id !== existingDance?.partnership_id));
  const availablePairs = activePairs.filter((pairing) => !usedPairIds.has(pairing.id));
  const existingPair = partnerships.find((pairing) => pairing.id === existingDance?.partnership_id);
  const selectablePairs = existingPair && !availablePairs.some((pairing) => pairing.id === existingPair.id) ? [...availablePairs, existingPair] : availablePairs;
  const castPicker = (excludedIds = []) => players.filter((player) => !excludedIds.includes(player.id)).map((player) => `<label class="cast-choice" data-dance-cast-name="${escapeHtml(player.name.toLowerCase())}" data-dance-cast-category="${castCategory(player)}" data-dance-bonus-category="${bonusCastCategory(player)}"><input type="checkbox" value="${player.id}" ${existingAppearanceIds.includes(player.id) ? 'checked' : ''}><span><b>${escapeHtml(player.name)}</b><small>${escapeHtml(player.role)}</small></span></label>`).join('');
  const drawForm = (kind) => {
    const judgeNames = ['Carrie Ann', 'Derek', 'Bruno', ...(week.guest_judge_name ? [week.guest_judge_name] : [])];
    const pairOptions = selectablePairs.map((pairing) => { const star = players.find((player) => player.id === pairing.star_id); const pro = players.find((player) => player.id === pairing.pro_id); return `<option value="${pairing.id}" ${pairing.id === existingDance?.partnership_id ? 'selected' : ''}>${escapeHtml(star.name)} & ${escapeHtml(pro.name)}</option>`; }).join('');
    $('#danceForm').innerHTML = `${kind === 'competitive' ? `<label class="couple-select">Couple<select id="dancePartnership"><option value="">Select couple</option>${pairOptions}</select></label><div class="dance-details"><label>Dance type <span class="optional">(optional)</span><input id="danceType" value="${escapeHtml(existingDance?.dance_type || '')}" placeholder="e.g., Cha-cha-cha"></label><label>Song <span class="optional">(optional)</span><input id="danceSong" value="${escapeHtml(existingDance?.song || '')}" placeholder="Song title"></label></div><div class="judge-grid">${judgeNames.map((judge) => `<label>${escapeHtml(judge)}<input data-judge="${escapeHtml(judge)}" type="number" min="0" max="10" inputmode="numeric" value="${existingScores.find((score) => score.judge_name === judge)?.score ?? ''}"></label>`).join('')}</div>` : `<label>Dance name <span class="optional">(optional)</span><input id="danceName" value="${escapeHtml(existingDance?.name || '')}" placeholder="Week ${week.number} Dance ${danceCount + 1}"></label>`}<h3>Cast appearances</h3><input id="danceCastSearch" placeholder="Search cast" autocomplete="off"><div class="filter-tabs" id="danceCastTabs"><button class="selected" data-dance-filter="all">All</button><button data-dance-filter="pros">Pros</button><button data-dance-filter="stars">Stars</button><button data-dance-filter="bonus">Bonus</button></div><div id="bonusDanceFilters" class="mini-filters" hidden><button class="selected" data-dance-bonus-filter="all">All bonus</button><button data-dance-bonus-filter="troupe">Troupe</button><button data-dance-bonus-filter="nextpro">Next Pro</button><button data-dance-bonus-filter="judges">Judges + Hosts</button></div><div id="danceCastPicker" class="cast-picker">${castPicker()}</div>`;
    let filter = 'all'; let bonusFilter = 'all'; let excluded = [];
    const filterCast = () => { const term = $('#danceCastSearch').value.toLowerCase(); document.querySelectorAll('[data-dance-cast-name]').forEach((item) => { const memberId = item.querySelector('input').value; item.hidden = !item.dataset.danceCastName.includes(term) || (filter !== 'all' && item.dataset.danceCastCategory !== filter) || (filter === 'bonus' && bonusFilter !== 'all' && item.dataset.danceBonusCategory !== bonusFilter) || excluded.includes(memberId); }); };
    $('#danceCastSearch').addEventListener('input', filterCast);
    document.querySelectorAll('[data-dance-filter]').forEach((button) => button.addEventListener('click', () => { filter = button.dataset.danceFilter; $('#bonusDanceFilters').hidden = filter !== 'bonus'; document.querySelectorAll('[data-dance-filter]').forEach((item) => item.classList.toggle('selected', item === button)); filterCast(); }));
    document.querySelectorAll('[data-dance-bonus-filter]').forEach((button) => button.addEventListener('click', () => { bonusFilter = button.dataset.danceBonusFilter; document.querySelectorAll('[data-dance-bonus-filter]').forEach((item) => item.classList.toggle('selected', item === button)); filterCast(); }));
    $('#dancePartnership')?.addEventListener('change', (event) => { const pairing = selectablePairs.find((item) => item.id === event.target.value); excluded = pairing ? [pairing.star_id, pairing.pro_id] : []; document.querySelectorAll('#danceCastPicker input').forEach((input) => { if (excluded.includes(input.value)) input.checked = false; }); filterCast(); });
  };
  openModal(`<h2>${existingDance ? 'Edit Dance' : 'Add Dance'}</h2><div class="filter-tabs dance-kind-tabs"><button ${!availablePairs.length && !existingDance ? 'disabled' : ''} class="${(existingDance?.kind || (availablePairs.length ? 'competitive' : 'performance')) === 'competitive' ? 'selected' : ''}" data-dance-kind="competitive">Competitive</button><button class="${(existingDance?.kind || (availablePairs.length ? 'competitive' : 'performance')) === 'performance' ? 'selected' : ''}" data-dance-kind="performance">Performance</button></div><div id="danceForm"></div><div class="modal-actions"><button id="saveDance">${existingDance ? 'Save changes' : 'Save dance'}</button></div>`);
  let kind = existingDance?.kind || (availablePairs.length ? 'competitive' : 'performance'); drawForm(kind);
  document.querySelectorAll('[data-dance-kind]').forEach((button) => button.addEventListener('click', () => { if (button.disabled) return; kind = button.dataset.danceKind; document.querySelectorAll('[data-dance-kind]').forEach((item) => item.classList.toggle('selected', item === button)); drawForm(kind); }));
  $('#saveDance').addEventListener('click', async () => {
    const partnership_id = kind === 'competitive' ? $('#dancePartnership').value || null : null;
    if (kind === 'competitive' && !partnership_id) return alert('Select the competing couple.');
    const name = kind === 'performance' ? $('#danceName').value.trim() || `Week ${week.number} Dance ${danceCount + 1}` : null;
    const dance_type = kind === 'competitive' ? $('#danceType').value.trim() || null : null;
    const song = kind === 'competitive' ? $('#danceSong').value.trim() || null : null;
    const danceOperation = existingDance ? db.from('dances').update({ kind, partnership_id, name, dance_type, song }).eq('id', existingDance.id).select().single() : db.from('dances').insert({ week_id: week.id, kind, partnership_id, name, dance_type, song, sort_order: danceCount + 1 }).select().single();
    const { data: dance, error: danceError } = await danceOperation;
    if (danceError) return alert(`Couldn’t save this dance: ${danceError.message}`);
    const scores = kind === 'competitive' ? [...document.querySelectorAll('[data-judge]')].filter((input) => input.value !== '').map((input) => ({ dance_id: dance.id, judge_name: input.dataset.judge, score: Number(input.value) })) : [];
    const appearances = [...document.querySelectorAll('#danceCastPicker input:checked')].map((input) => ({ dance_id: dance.id, cast_member_id: input.value }));
    if (existingDance) { await db.from('dance_judge_scores').delete().eq('dance_id', dance.id); await db.from('dance_appearances').delete().eq('dance_id', dance.id); }
    if (scores.length) { const { error: scoreError } = await db.from('dance_judge_scores').insert(scores); if (scoreError) return alert(`Dance saved, but judge scores could not be saved: ${scoreError.message}`); }
    if (appearances.length) { const { error: appearanceError } = await db.from('dance_appearances').insert(appearances); if (appearanceError) return alert(`Dance saved, but appearances could not be saved: ${appearanceError.message}`); }
    $('#modal').close(); loadScoreDesk(); loadRoster(); loadStandings();
  });
}

async function openEditDance(week, dance, index) {
  const [{ data: scores, error: scoreError }, { data: appearances, error: appearanceError }] = await Promise.all([
    db.from('dance_judge_scores').select('judge_name,score').eq('dance_id', dance.id),
    db.from('dance_appearances').select('cast_member_id').eq('dance_id', dance.id),
  ]);
  if (scoreError || appearanceError) return alert(`Couldn’t open this dance: ${scoreError?.message || appearanceError?.message}`);
  openNewDance(week, index, dance, scores, appearances.map((item) => item.cast_member_id));
}

$('#rosterSearch').addEventListener('input', loadRoster);
document.querySelectorAll('[data-roster-filter]').forEach((button) => button.addEventListener('click', () => {
  rosterFilter = button.dataset.rosterFilter;
  document.querySelectorAll('[data-roster-filter]').forEach((item) => item.classList.toggle('selected', item === button));
  loadRoster();
}));
$('#newPlayer').addEventListener('click', openAddPlayer);
$('#newTeam').addEventListener('click', openNewTeam);
$('#newWeek').addEventListener('click', openNewWeek);
window.addEventListener('mirrorball-auth-change', async (event) => {
  canEdit = event.detail.signedIn;
  $('#newPlayer').hidden = !canEdit;
  $('#newTeam').hidden = !canEdit;
  $('#newWeek').hidden = !canEdit;
  loadStandings();
  loadRoster();
  loadTeams();
  loadScoreDesk();
});
db.auth.getSession().then(({ data: { session } }) => {
  canEdit = Boolean(session);
  $('#newPlayer').hidden = !canEdit;
  $('#newTeam').hidden = !canEdit;
  $('#newWeek').hidden = !canEdit;
  loadStandings();
  loadRoster();
  loadTeams();
  loadScoreDesk();
});
