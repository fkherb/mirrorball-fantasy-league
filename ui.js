import { db } from './supabase-client.js';

document.addEventListener('DOMContentLoaded', async () => {
  const buttons = [...document.querySelectorAll('nav button[data-view]')];
  const views = [...document.querySelectorAll('.view')];
  const navToggle = document.querySelector('#navToggle');
  const navStateKey = 'mirrorball-nav-state-v2';
  const storedNavState = localStorage.getItem(navStateKey);
  const defaultNavCollapsed = window.matchMedia('(max-width: 1100px)').matches;
  const setNavCollapsed = (collapsed) => {
    document.body.classList.toggle('nav-collapsed', collapsed);
    if (!navToggle) return;
    const mobile = window.matchMedia('(max-width: 750px)').matches;
    navToggle.setAttribute('aria-expanded', String(!collapsed));
    navToggle.setAttribute('aria-label', collapsed ? 'Expand navigation' : 'Collapse navigation');
    navToggle.querySelector('.nav-toggle-icon').textContent = mobile ? (collapsed ? '☰' : '×') : (collapsed ? '›' : '‹');
    navToggle.querySelector('.nav-toggle-label').textContent = mobile ? (collapsed ? 'Menu' : 'Close') : (collapsed ? 'Expand' : 'Collapse');
  };
  setNavCollapsed(storedNavState ? storedNavState === 'collapsed' : defaultNavCollapsed);
  const mobileNavQuery = window.matchMedia('(max-width: 750px)');
  mobileNavQuery.addEventListener('change', () => setNavCollapsed(document.body.classList.contains('nav-collapsed')));
  navToggle?.addEventListener('click', () => {
    const collapsed = !document.body.classList.contains('nav-collapsed');
    setNavCollapsed(collapsed);
    localStorage.setItem(navStateKey, collapsed ? 'collapsed' : 'expanded');
  });
  const rememberedViews = new Set(['standings', 'teams', 'score', 'league']);
  const storedView = localStorage.getItem('mirrorball-active-view');
  let requestedView = rememberedViews.has(location.hash.slice(1))
    ? location.hash.slice(1)
    : rememberedViews.has(storedView) ? storedView : 'standings';
  const openView = (name, remember = true) => {
    if (!views.some((view) => view.id === name)) name = 'standings';
    views.forEach((view) => view.classList.toggle('active', view.id === name));
    buttons.forEach((button) => button.classList.toggle('active', button.dataset.view === name));
    buttons.find((button) => button.dataset.view === name)?.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' });
    if (remember && rememberedViews.has(name)) {
      requestedView = name;
      localStorage.setItem('mirrorball-active-view', name);
      history.replaceState(null, '', `${location.pathname}${location.search}#${name}`);
    }
  };
  buttons.forEach((button) => button.addEventListener('click', () => openView(button.dataset.view)));

  const auth = document.querySelector('#auth');
  const menu = document.querySelector('#accountMenu');
  const email = document.querySelector('#accountEmail');
  const usernameInput = document.querySelector('#accountUsername');
  const displayNameInput = document.querySelector('#accountDisplayName');
  const avatarUrlInput = document.querySelector('#accountAvatarUrl');
  const profileHint = document.querySelector('#accountProfileHint');
  const myTeamNav = document.querySelector('#myTeamNav');
  const scoreDeskLink = document.querySelector('#scoreDeskLink');
  const castRosterLink = document.querySelector('#castRosterLink');
  let currentSession = null;
  let currentMember = null;
  let currentProfile = null;
  let membershipReady = false;

  const missingMembershipTable = (error) => ['42P01', 'PGRST205'].includes(error?.code) || /league_members/i.test(error?.message || '') && /not find|does not exist/i.test(error.message);

  async function showAccess(session) {
    currentSession = session;
    const signedInEmail = session?.user?.email;
    const metadata = session?.user?.user_metadata || {};
    currentMember = null;
    currentProfile = null;
    membershipReady = false;
    let membershipError = null;
    let isPlatformAdmin = false;
    let teamName = '';
    if (session?.user) {
      const [contextResult, platformResult] = await Promise.all([
        db.rpc('get_my_account_context'),
        db.rpc('is_platform_admin'),
      ]);
      if (!contextResult.error) {
        currentProfile = contextResult.data?.profile || null;
        currentMember = contextResult.data?.membership || null;
        teamName = contextResult.data?.team_name || '';
        membershipReady = true;
      } else {
        // Allows the site to stay usable while the profile migration is being deployed.
        const membershipResult = await db.from('league_members').select('*').eq('user_id', session.user.id).maybeSingle();
        membershipError = membershipResult.error;
        membershipReady = !membershipResult.error;
        currentMember = membershipResult.data || null;
      }
      isPlatformAdmin = platformResult.data === true;
    }
    const legacyName = [currentMember?.first_name, currentMember?.last_name].filter(Boolean).join(' ') || metadata.display_name || metadata.full_name || metadata.name || '';
    const displayName = currentProfile?.display_name || legacyName;
    const [firstName = '', ...remainingNames] = displayName.trim().split(/\s+/).filter(Boolean);
    const lastName = remainingNames.join(' ');
    if (!teamName && currentMember?.fantasy_team_id) {
      const { data: team } = await db.from('fantasy_teams').select('team_name').eq('id', currentMember.fantasy_team_id).maybeSingle();
      teamName = team?.team_name || '';
    }
    const legacyCommissioner = signedInEmail === 'herbfreddy@gmail.com' && (missingMembershipTable(membershipError) || !currentMember);
    const isCommissioner = Boolean(currentMember?.is_commissioner) || legacyCommissioner;
    auth.textContent = signedInEmail ? firstName || displayName || 'Signed in' : 'Sign in';
    email.textContent = signedInEmail || '';
    usernameInput.value = currentProfile?.username || '';
    displayNameInput.value = displayName;
    avatarUrlInput.value = currentProfile?.avatar_url || '';
    profileHint.hidden = currentProfile?.onboarding_completed !== false;
    const labelMode = currentMember?.team_nav_label_mode || 'default';
    const teamNavLabel = labelMode === 'custom' && currentMember?.custom_team_nav_label
      ? currentMember.custom_team_nav_label
      : labelMode === 'team' && teamName ? teamName : 'My Team';
    myTeamNav.querySelector('.nav-label').textContent = teamNavLabel;
    myTeamNav.setAttribute('aria-label', teamNavLabel);
    myTeamNav.hidden = !signedInEmail || (membershipReady && !currentMember?.fantasy_team_id);
    scoreDeskLink.hidden = !isPlatformAdmin;
    castRosterLink.hidden = !isPlatformAdmin;
    if (requestedView === 'teams' && myTeamNav.hidden) openView('standings', false);
    else openView(requestedView, false);
    menu.hidden = true;
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: { signedIn: Boolean(signedInEmail), email: signedInEmail, firstName, lastName, displayName, username: currentProfile?.username || '', avatarUrl: currentProfile?.avatar_url || '', teamName, teamNavLabelMode: labelMode, customTeamNavLabel: currentMember?.custom_team_nav_label || '', isCommissioner, isPlatformAdmin, fantasyTeamId: currentMember?.fantasy_team_id || null, membershipReady } }));
  }

  const { data: { session } } = await db.auth.getSession();
  await showAccess(session);
  window.addEventListener('hashchange', () => {
    const view = location.hash.slice(1);
    if (rememberedViews.has(view)) {
      requestedView = view;
      if (view !== 'teams' || !myTeamNav.hidden) openView(view, false);
    }
  });
  db.auth.onAuthStateChange((_event, nextSession) => { queueMicrotask(() => showAccess(nextSession)); });

  auth.addEventListener('click', () => {
    const signedIn = Boolean(currentSession);
    if (!signedIn) return openView('signin');
    menu.hidden = !menu.hidden;
  });
  document.querySelector('#saveAccountProfile').addEventListener('click', async () => {
    const button = document.querySelector('#saveAccountProfile');
    const username = usernameInput.value.trim().toLowerCase();
    const displayName = displayNameInput.value.trim();
    const avatarUrl = avatarUrlInput.value.trim();
    usernameInput.value = username;
    if (!/^[a-z0-9_]{3,20}$/.test(username)) return alert('Username must be 3–20 characters using lowercase letters, numbers, or underscores.');
    if (!displayName || displayName.length > 80) return alert('Enter a display name of 80 characters or fewer.');
    if (avatarUrl && !/^https:\/\//i.test(avatarUrl)) return alert('Avatar URL must start with https://');
    button.disabled = true;
    button.textContent = 'Saving…';
    const { error } = await db.rpc('update_my_profile', { p_username: username, p_display_name: displayName, p_avatar_url: avatarUrl || null });
    button.disabled = false;
    button.textContent = 'Save profile';
    if (error) return alert(error.message.includes('already taken') ? 'That username is already taken.' : `Couldn’t save your profile: ${error.message}`);
    await showAccess(currentSession);
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
