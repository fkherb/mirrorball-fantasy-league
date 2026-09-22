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
  const accountName = document.querySelector('#accountName');
  let currentSession = null;

  function showAccess(session) {
    currentSession = session;
    const signedInEmail = session?.user?.email;
    const displayName = session?.user?.user_metadata?.display_name || session?.user?.user_metadata?.full_name || session?.user?.user_metadata?.name;
    auth.textContent = signedInEmail ? displayName || 'Signed in' : 'Sign in';
    email.textContent = signedInEmail || '';
    accountName.value = displayName || '';
    menu.hidden = true;
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: { signedIn: Boolean(signedInEmail), email: signedInEmail, displayName } }));
  }

  const { data: { session } } = await db.auth.getSession();
  showAccess(session);
  db.auth.onAuthStateChange((_event, nextSession) => showAccess(nextSession));

  auth.addEventListener('click', () => {
    const signedIn = Boolean(currentSession);
    if (!signedIn) return openView('signin');
    menu.hidden = !menu.hidden;
  });
  document.querySelector('#saveAccountName').addEventListener('click', async () => {
    const displayName = accountName.value.trim();
    if (!displayName) return alert('Enter the name you want displayed in the league.');
    const { data, error } = await db.auth.updateUser({ data: { display_name: displayName } });
    if (error) return alert(`Couldn’t save your name: ${error.message}`);
    showAccess({ ...currentSession, user: data.user });
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
