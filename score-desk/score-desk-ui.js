import { db } from '../supabase-client.js';

document.addEventListener('DOMContentLoaded', async () => {
  const authButton = document.querySelector('#adminAuth');
  const menu = document.querySelector('#adminAccountMenu');
  const emailLabel = document.querySelector('#adminAccountEmail');
  const gate = document.querySelector('#scoreDeskGate');
  const gateMessage = document.querySelector('#scoreDeskGateMessage');
  const signInForm = document.querySelector('#scoreDeskSignIn');
  const app = document.querySelector('#scoreDeskApp');
  let currentSession = null;

  async function showAccess(session) {
    currentSession = session;
    const signedInEmail = session?.user?.email || '';
    let firstName = session?.user?.user_metadata?.first_name || '';
    let isPlatformAdmin = false;
    if (session?.user) {
      const [memberResult, platformResult] = await Promise.all([
        db.from('league_members').select('first_name').eq('user_id', session.user.id).maybeSingle(),
        db.rpc('is_platform_admin'),
      ]);
      firstName = memberResult.data?.first_name || firstName;
      isPlatformAdmin = platformResult.data === true;
    }

    authButton.textContent = signedInEmail ? firstName || 'Signed in' : 'Sign in';
    emailLabel.textContent = signedInEmail;
    menu.hidden = true;
    signInForm.hidden = Boolean(signedInEmail);
    gate.hidden = isPlatformAdmin;
    app.hidden = !isPlatformAdmin;
    gateMessage.textContent = !signedInEmail
      ? 'Sign in with the platform-owner account to continue.'
      : isPlatformAdmin ? '' : 'This account can manage its league, but it cannot change canonical show data.';
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: { signedIn: Boolean(signedInEmail), isCommissioner: false, isPlatformAdmin } }));
  }

  const { data: { session } } = await db.auth.getSession();
  await showAccess(session);
  db.auth.onAuthStateChange((_event, nextSession) => { queueMicrotask(() => showAccess(nextSession)); });

  authButton.addEventListener('click', () => {
    if (!currentSession) return document.querySelector('#adminEmail').focus();
    menu.hidden = !menu.hidden;
  });
  document.querySelector('#adminSignIn').addEventListener('click', async () => {
    const button = document.querySelector('#adminSignIn');
    button.disabled = true;
    button.textContent = 'Signing in…';
    const { error } = await db.auth.signInWithPassword({ email: document.querySelector('#adminEmail').value.trim(), password: document.querySelector('#adminPassword').value });
    button.disabled = false;
    button.textContent = 'Sign in';
    if (error) alert(error.message);
  });
  document.querySelector('#adminSignOut').addEventListener('click', async () => { await db.auth.signOut(); });
});
