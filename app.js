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

function showRosterMessage(message, isError = false) {
  $('#rosterResults').innerHTML = `<p class="sub ${isError ? 'error' : ''}">${message}</p>`;
}

function openModal(contents) {
  $('#modalBody').innerHTML = `<div class="modal">${contents}</div>`;
  $('#modal').showModal();
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
  const players = allPlayers.filter((player) => player.name.toLowerCase().includes(query.toLowerCase()));
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

$('#rosterSearch').addEventListener('input', loadRoster);
$('#newPlayer').addEventListener('click', openAddPlayer);
window.addEventListener('mirrorball-auth-change', async (event) => {
  canEdit = event.detail.signedIn;
  $('#newPlayer').hidden = !canEdit;
  loadRoster();
});
db.auth.getSession().then(({ data: { session } }) => {
  canEdit = Boolean(session);
  $('#newPlayer').hidden = !canEdit;
  loadRoster();
});
