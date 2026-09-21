import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const db = createClient('https://mdrrnanxqazecqviaass.supabase.co', 'sb_publishable_ylMIgpLXA0NBoeb3aPI8qQ_m0wrG7It');
const $ = (selector) => document.querySelector(selector);
const roles = ['Star', 'Pro', 'Troupe', 'DWTS Next Pro', 'Hough', 'Judges + Hosts', 'Surprise'];
const imagePathFor = (name) => `Images/${name.replace(/[.,'’]/g, '')}.jpg`;

function showRosterMessage(message, isError = false) {
  $('#rosterResults').innerHTML = `<p class="sub ${isError ? 'error' : ''}">${message}</p>`;
}

function openModal(contents) {
  $('#modalBody').innerHTML = `<div class="modal">${contents}</div>`;
  $('#modal').showModal();
}

async function loadRoster() {
  const query = $('#rosterSearch').value.trim();
  const { data: players, error } = await db.from('players').select('*').ilike('name', `%${query}%`).order('name');
  if (error) return showRosterMessage(`Couldn’t load the roster: ${error.message}`, true);
  if (!players.length) return showRosterMessage('No players yet. Add them manually.');
  $('#rosterResults').innerHTML = players.map((player) => `
    <div class="row"><img class="player-photo" src="${player.image_path || imagePathFor(player.name)}" alt="">
      <span><b>${player.name}</b><small>${player.role}${player.role === 'Surprise' && player.custom_appearance_points ? ` · +${player.custom_appearance_points}` : ''}</small></span>
      <button data-player-id="${player.id}">Edit</button>
    </div>`).join('');
  document.querySelectorAll('[data-player-id]').forEach((button) => button.addEventListener('click', () => editPlayer(button.dataset.playerId)));
}

async function editPlayer(id) {
  const { data: player, error } = await db.from('players').select('*').eq('id', id).single();
  if (error) return alert(`Couldn’t open this player: ${error.message}`);
  openModal(`<h2>${player.name}</h2><p class="sub">Pairings and elimination controls will be added next.</p>
    <label>Role<select id="editRole">${roles.map((role) => `<option ${role === player.role ? 'selected' : ''}>${role}</option>`).join('')}</select></label>
    <label id="surpriseRate" ${player.role === 'Surprise' ? '' : 'hidden'}>Points per appearance<input id="editRate" type="number" min="0" value="${player.custom_appearance_points ?? ''}"></label>
    <button id="savePlayer">Save changes</button><button id="deletePlayer" class="danger">Delete player</button>`);
  $('#editRole').addEventListener('change', (event) => { $('#surpriseRate').hidden = event.target.value !== 'Surprise'; });
  $('#savePlayer').addEventListener('click', async () => {
    const role = $('#editRole').value;
    const { error: saveError } = await db.from('players').update({ role, custom_appearance_points: role === 'Surprise' ? Number($('#editRate').value) || null : null, image_path: player.image_path || imagePathFor(player.name) }).eq('id', id);
    if (saveError) return alert(`Couldn’t save ${player.name}: ${saveError.message}`);
    $('#modal').close(); loadRoster();
  });
  $('#deletePlayer').addEventListener('click', async () => {
    if (!confirm(`Delete ${player.name}? This cannot be undone.`)) return;
    const { error: deleteError } = await db.from('players').delete().eq('id', id);
    if (deleteError) return alert(`Couldn’t delete ${player.name}: ${deleteError.message}`);
    $('#modal').close(); loadRoster();
  });
}

function openAddPlayer() {
  openModal(`<h2>Add Player</h2><p class="sub">Their image path will be set automatically from their name.</p>
    <label>Name<input id="newName" autocomplete="off" required></label>
    <label>Role<select id="newRole">${roles.map((role) => `<option>${role}</option>`).join('')}</select></label>
    <label id="newSurpriseRate" hidden>Points per appearance<input id="newRate" type="number" min="0"></label>
    <button id="createPlayer">Create player</button>`);
  $('#newRole').addEventListener('change', (event) => { $('#newSurpriseRate').hidden = event.target.value !== 'Surprise'; });
  $('#createPlayer').addEventListener('click', async () => {
    const name = $('#newName').value.trim();
    if (!name) return alert('Enter a player name first.');
    const role = $('#newRole').value;
    const { error } = await db.from('players').insert({ name, role, image_path: imagePathFor(name), custom_appearance_points: role === 'Surprise' ? Number($('#newRate').value) || null : null });
    if (error) return alert(`Couldn’t create ${name}: ${error.message}`);
    $('#modal').close(); loadRoster();
  });
}

$('#rosterSearch').addEventListener('input', loadRoster);
$('#newPlayer').addEventListener('click', openAddPlayer);
loadRoster();
