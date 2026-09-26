import { db } from '../supabase-client.js';

document.addEventListener('DOMContentLoaded', async () => {
  const authButton = document.querySelector('#adminAuth');
  const menu = document.querySelector('#adminAccountMenu');
  const gate = document.querySelector('#adminGate');
  const app = document.querySelector('#adminApp');
  let currentSession = null;

  async function showAccess(session) {
    currentSession = session;
    const email = session?.user?.email || '';
    let displayName = session?.user?.user_metadata?.display_name || session?.user?.user_metadata?.first_name || '';
    let isPlatformAdmin = false;
    if (session?.user) {
      const [contextResult, platformResult] = await Promise.all([
        db.rpc('get_my_account_context'),
        db.rpc('is_platform_admin'),
      ]);
      displayName = contextResult.data?.profile?.display_name || displayName;
      isPlatformAdmin = platformResult.data === true;
    }
    authButton.textContent = email ? displayName.split(/\s+/)[0] || 'Signed in' : 'Sign in';
    document.querySelector('#adminAccountEmail').textContent = email;
    menu.hidden = true;
    document.querySelector('#adminSignInForm').hidden = Boolean(email);
    gate.hidden = isPlatformAdmin;
    app.hidden = !isPlatformAdmin;
    document.querySelector('#adminGateMessage').textContent = !email ? 'Sign in with the platform-owner account to continue.' : isPlatformAdmin ? '' : 'This workspace is available only to the platform owner.';
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: { signedIn: Boolean(email), isCommissioner: false, isPlatformAdmin } }));
  }

  const { data: { session } } = await db.auth.getSession();
  await showAccess(session);
  db.auth.onAuthStateChange((_event, nextSession) => { queueMicrotask(() => showAccess(nextSession)); });
  authButton.addEventListener('click', () => { if (!currentSession) return document.querySelector('#adminEmail').focus(); menu.hidden = !menu.hidden; });
  document.querySelector('#adminSignIn').addEventListener('click', async () => {
    const button = document.querySelector('#adminSignIn');
    button.disabled = true; button.textContent = 'Signing in…';
    const { error } = await db.auth.signInWithPassword({ email: document.querySelector('#adminEmail').value.trim(), password: document.querySelector('#adminPassword').value });
    button.disabled = false; button.textContent = 'Sign in';
    if (error) alert(error.message);
  });
  document.querySelector('#adminSignOut').addEventListener('click', async () => { await db.auth.signOut(); });
});
