document.addEventListener('DOMContentLoaded', async () => {
  const buttons = [...document.querySelectorAll('nav button')];
  const views = [...document.querySelectorAll('.view')];
  const openView = (name) => {
    views.forEach((view) => view.classList.toggle('active', view.id === name));
    buttons.forEach((button) => button.classList.toggle('active', button.dataset.view === name));
  };
  buttons.forEach((button) => button.addEventListener('click', () => openView(button.dataset.view)));

  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
  const db = createClient('https://mdrrnanxqazecqviaass.supabase.co', 'sb_publishable_ylMIgpLXA0NBoeb3aPI8qQ_m0wrG7It');
  const auth = document.querySelector('#auth');
  const menu = document.querySelector('#accountMenu');
  const email = document.querySelector('#accountEmail');

  function showAccess(session) {
    const signedInEmail = session?.user?.email;
    auth.textContent = signedInEmail || 'Sign in';
    email.textContent = signedInEmail || '';
    menu.hidden = true;
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: { signedIn: Boolean(signedInEmail), email: signedInEmail } }));
  }

  const { data: { session } } = await db.auth.getSession();
  showAccess(session);
  db.auth.onAuthStateChange((_event, nextSession) => showAccess(nextSession));

  auth.addEventListener('click', () => {
    const signedIn = Boolean(email.textContent);
    if (!signedIn) return openView('signin');
    menu.hidden = !menu.hidden;
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
