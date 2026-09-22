import { db } from './supabase-client.js';

document.addEventListener('DOMContentLoaded', async () => {
  const buttons = [...document.querySelectorAll('nav button')];
  const views = [...document.querySelectorAll('.view')];
  const openView = (name) => {
    views.forEach((view) => view.classList.toggle('active', view.id === name));
    buttons.forEach((button) => button.classList.toggle('active', button.dataset.view === name));
    buttons.find((button) => button.dataset.view === name)?.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' });
  };
  buttons.forEach((button) => button.addEventListener('click', () => openView(button.dataset.view)));

  const auth = document.querySelector('#auth');
  const menu = document.querySelector('#accountMenu');
  const email = document.querySelector('#accountEmail');
  const firstNameInput = document.querySelector('#accountFirstName');
  const lastNameInput = document.querySelector('#accountLastName');
  const nameEditor = document.querySelector('#accountNameEditor');
  const myTeamNav = document.querySelector('#myTeamNav');
  let currentSession = null;
  let currentMember = null;
  let membershipReady = false;

  const missingMembershipTable = (error) => ['42P01', 'PGRST205'].includes(error?.code) || /league_members/i.test(error?.message || '') && /not find|does not exist/i.test(error.message);

  async function showAccess(session) {
    currentSession = session;
    const signedInEmail = session?.user?.email;
    const metadata = session?.user?.user_metadata || {};
    currentMember = null;
    membershipReady = false;
    let membershipError = null;
    if (session?.user) {
      const { data, error } = await db.from('league_members').select('*').eq('user_id', session.user.id).maybeSingle();
      membershipError = error;
      membershipReady = !error;
      currentMember = data || null;
    }
    const firstName = currentMember?.first_name || metadata.first_name || '';
    const lastName = currentMember?.last_name || metadata.last_name || '';
    const displayName = [firstName, lastName].filter(Boolean).join(' ') || metadata.display_name || metadata.full_name || metadata.name;
    let teamName = '';
    if (currentMember?.fantasy_team_id) {
      const { data: team } = await db.from('fantasy_teams').select('team_name').eq('id', currentMember.fantasy_team_id).maybeSingle();
      teamName = team?.team_name || '';
    }
    const legacyCommissioner = signedInEmail === 'herbfreddy@gmail.com' && (missingMembershipTable(membershipError) || !currentMember);
    const isCommissioner = Boolean(currentMember?.is_commissioner) || legacyCommissioner;
    auth.textContent = signedInEmail ? firstName || displayName || 'Signed in' : 'Sign in';
    email.textContent = signedInEmail || '';
    firstNameInput.value = firstName;
    lastNameInput.value = lastName;
    nameEditor.hidden = Boolean(firstName && lastName);
    const labelMode = currentMember?.team_nav_label_mode || 'default';
    myTeamNav.textContent = labelMode === 'custom' && currentMember?.custom_team_nav_label
      ? currentMember.custom_team_nav_label
      : labelMode === 'team' && teamName ? teamName : 'My Team';
    myTeamNav.hidden = !signedInEmail || (membershipReady && !currentMember?.fantasy_team_id);
    if (myTeamNav.hidden && document.querySelector('#teams').classList.contains('active')) openView('standings');
    menu.hidden = true;
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: { signedIn: Boolean(signedInEmail), email: signedInEmail, firstName, lastName, displayName, teamName, teamNavLabelMode: labelMode, customTeamNavLabel: currentMember?.custom_team_nav_label || '', isCommissioner, fantasyTeamId: currentMember?.fantasy_team_id || null, membershipReady } }));
  }

  const { data: { session } } = await db.auth.getSession();
  await showAccess(session);
  db.auth.onAuthStateChange((_event, nextSession) => { queueMicrotask(() => showAccess(nextSession)); });

  auth.addEventListener('click', () => {
    const signedIn = Boolean(currentSession);
    if (!signedIn) return openView('signin');
    menu.hidden = !menu.hidden;
  });
  document.querySelector('#saveAccountName').addEventListener('click', async () => {
    const firstName = firstNameInput.value.trim();
    const lastName = lastNameInput.value.trim();
    if (!firstName || !lastName) return alert('Enter both your first and last name.');
    const displayName = `${firstName} ${lastName}`;
    const { data, error } = await db.auth.updateUser({ data: { first_name: firstName, last_name: lastName, display_name: displayName } });
    if (error) return alert(`Couldn’t save your name: ${error.message}`);
    if (membershipReady && currentMember) {
      const { error: memberError } = await db.rpc('update_my_league_name', { p_first_name: firstName, p_last_name: lastName });
      if (memberError) return alert(`Your sign-in name was saved, but the league profile could not be updated: ${memberError.message}`);
    }
    await showAccess({ ...currentSession, user: data.user });
  });
  document.querySelector('#magic').addEventListener('click', async () => {
    const button = document.querySelector('#magic');
    button.disabled = true; button.textContent = 'Signing in…';
    const { error } = await db.auth.signInWithPassword({ email: document.querySelector('#email').value.trim(), password: document.querySelector('#password').value });
    button.disabled = false; button.textContent = 'Sign in';
    if (error) return alert(error.message);
    openView('standings');
  });
  document.querySelector('#signOut').addEventListener('click', async () => { await db.auth.signOut(); });
});
