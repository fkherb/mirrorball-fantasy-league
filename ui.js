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
  const providerLinks = document.createElement('div');
  providerLinks.className = 'account-provider-links';
  providerLinks.innerHTML = '<p class="eyebrow">Sign-in methods</p><button id="connectGoogle" type="button" class="secondary">Connect Google</button><button id="connectApple" type="button" class="secondary">Connect Apple</button><p id="providerLinkMessage" class="account-profile-hint" role="status"></p>';
  menu.querySelector('.account-admin-links').before(providerLinks);
  const email = document.querySelector('#accountEmail');
  const usernameInput = document.querySelector('#accountUsername');
  const displayNameInput = document.querySelector('#accountDisplayName');
  const picturePreview = document.querySelector('#accountPicturePreview');
  const pictureInitial = document.querySelector('#accountPictureInitial');
  const pictureFile = document.querySelector('#accountPictureFile');
  const picturePicker = document.querySelector('#chooseCastPicture');
  const pictureClear = document.querySelector('#clearAccountPicture');
  const pictureButton = document.querySelector('#accountPictureButton');
  const pictureOptions = document.querySelector('#accountPictureOptions');
  const profileFields = document.querySelector('#accountProfileFields');
  const profileActions = document.querySelector('#accountProfileActions');
  const profileEdit = document.querySelector('#editAccountProfile');
  const profileCancel = document.querySelector('#cancelAccountProfile');
  const profileHint = document.querySelector('#accountProfileHint');
  const myTeamNav = document.querySelector('#myTeamNav');
  const scoreDeskLink = document.querySelector('#scoreDeskLink');
  const castRosterLink = document.querySelector('#castRosterLink');
  const myLeaguesNav = document.querySelector('#myLeaguesNav');
  const defaultLeagueId = '00000000-0000-4000-8000-000000000001';
  const joinToken = new URLSearchParams(location.search).get('join');
  let currentSession = null;
  let currentMember = null;
  let currentProfile = null;
  let membershipReady = false;
  let accessVersion = 0;
  let currentAccessDetail = null;
  let selectedAvatarUrl = '';
  let pendingPicture = null;
  let previewObjectUrl = null;
  let profileEditing = false;
  let pictureDirty = false;
  const syncProfileControls = () => {
    profileFields.hidden = !profileEditing;
    profileActions.hidden = !profileEditing && !pictureDirty;
    profileEdit.textContent = profileEditing ? 'Editing' : 'Edit';
    profileEdit.disabled = profileEditing;
  };
  const markPictureDirty = () => {
    pictureDirty = true;
    pictureOptions.hidden = true;
    pictureButton.setAttribute('aria-expanded', 'false');
    syncProfileControls();
  };

  const updatePicturePreview = (url, name = '') => {
    picturePreview.hidden = !url;
    pictureInitial.hidden = Boolean(url);
    if (url) picturePreview.src = url;
    else picturePreview.removeAttribute('src');
    pictureInitial.textContent = (name.trim()[0] || '?').toUpperCase();
  };
  const releasePreview = () => {
    if (previewObjectUrl) URL.revokeObjectURL(previewObjectUrl);
    previewObjectUrl = null;
  };

  document.querySelector('main').prepend(document.querySelector('#joinInviteBanner'));

  pictureFile.addEventListener('change', () => {
    const file = pictureFile.files?.[0];
    if (!file) return;
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 2 * 1024 * 1024) {
      pictureFile.value = '';
      alert('Choose a JPEG, PNG, or WebP image under 2 MB.');
      return;
    }
    releasePreview();
    pendingPicture = file;
    selectedAvatarUrl = '';
    previewObjectUrl = URL.createObjectURL(file);
    updatePicturePreview(previewObjectUrl, displayNameInput.value);
    markPictureDirty();
  });
  const uploadLabel = document.querySelector('.account-upload-label');
  uploadLabel.tabIndex = 0;
  uploadLabel.setAttribute('role', 'button');
  uploadLabel.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      pictureFile.click();
    }
  });
  pictureClear.addEventListener('click', () => {
    releasePreview();
    pendingPicture = null;
    pictureFile.value = '';
    selectedAvatarUrl = '';
    updatePicturePreview('', displayNameInput.value);
    markPictureDirty();
  });
  pictureButton.addEventListener('click', () => {
    pictureOptions.hidden = !pictureOptions.hidden;
    pictureButton.setAttribute('aria-expanded', String(!pictureOptions.hidden));
  });
  profileEdit.addEventListener('click', () => {
    profileEditing = true;
    syncProfileControls();
    usernameInput.focus();
  });
  profileCancel.addEventListener('click', () => {
    releasePreview();
    pendingPicture = null;
    pictureFile.value = '';
    pictureDirty = false;
    profileEditing = false;
    usernameInput.value = currentProfile?.username || '';
    displayNameInput.value = currentProfile?.display_name || '';
    selectedAvatarUrl = currentProfile?.avatar_url || '';
    updatePicturePreview(selectedAvatarUrl, displayNameInput.value);
    pictureOptions.hidden = true;
    pictureButton.setAttribute('aria-expanded', 'false');
    syncProfileControls();
  });
  picturePicker.addEventListener('click', async () => {
    picturePicker.disabled = true;
    const { data, error } = await db.from('cast_members').select('name,image_path').order('name');
    picturePicker.disabled = false;
    if (error) return alert('Couldn’t load cast photos. Please try again.');
    const modal = document.querySelector('#modal');
    const body = document.querySelector('#modalBody');
    body.replaceChildren();
    const heading = document.createElement('h2');
    heading.textContent = 'Choose a cast photo';
    const grid = document.createElement('div');
    grid.className = 'account-picture-grid';
    for (const member of data || []) {
      const path = member.image_path || `Images/${member.name.replace(/[.,'’]/g, '')}.jpg`;
      const url = new URL(path.replace(/^\.\//, ''), location.href).toString();
      if (!url.startsWith('https://')) continue;
      const choice = document.createElement('button');
      choice.type = 'button';
      choice.className = 'account-picture-choice';
      const image = document.createElement('img');
      image.src = url;
      image.alt = '';
      image.addEventListener('error', () => choice.remove());
      const label = document.createElement('span');
      label.textContent = member.name;
      choice.append(image, label);
      choice.addEventListener('click', (event) => {
        event.stopPropagation();
        releasePreview();
        pendingPicture = null;
        pictureFile.value = '';
        selectedAvatarUrl = url;
        updatePicturePreview(url, displayNameInput.value);
        markPictureDirty();
        modal.close();
        menu.hidden = false;
        auth.setAttribute('aria-expanded', 'true');
      });
      grid.append(choice);
    }
    body.append(heading, grid);
    modal.dataset.dirty = 'false';
    document.querySelector('#modalClose').onclick = () => modal.close();
    modal.oncancel = null;
    if (!modal.open) modal.showModal();
  });

  async function showAccess(session) {
    const version = ++accessVersion;
    const previousUserId = currentSession?.user?.id;
    currentSession = session;
    const signedInEmail = session?.user?.email;
    const metadata = session?.user?.user_metadata || {};
    currentMember = null;
    currentProfile = null;
    membershipReady = false;
    let isPlatformAdmin = false;
    let teamName = '';
    let leagues = [];
    let leaguesError = false;
    if (session?.user) {
      const [contextResult, platformResult, leaguesResult] = await Promise.all([
        db.rpc('get_my_account_context'),
        db.rpc('is_platform_admin'),
        db.rpc('get_my_leagues'),
      ]);
      if (version !== accessVersion) return;
      leagues = leaguesResult.data || [];
      leaguesError = Boolean(leaguesResult.error);
      if (leaguesResult.error) console.error('Could not load account leagues', leaguesResult.error);
      if (!contextResult.error) {
        currentProfile = contextResult.data?.profile || null;
        currentMember = contextResult.data?.membership || null;
        teamName = contextResult.data?.team_name || '';
        membershipReady = true;
      } else {
        // Allows the site to stay usable while the profile migration is being deployed.
        const membershipResult = await db.from('league_members').select('*')
          .eq('league_id', defaultLeagueId).eq('user_id', session.user.id).maybeSingle();
        if (version !== accessVersion) return;
        membershipReady = !membershipResult.error;
        currentMember = membershipResult.data || null;
      }
      isPlatformAdmin = platformResult.data === true;
    }
    const requestedLeagueId = new URLSearchParams(location.search).get('league')
      || localStorage.getItem('mirrorball-active-league') || defaultLeagueId;
    const selectedLeague = leagues.find((league) => league.league_id === requestedLeagueId)
      || leagues.find((league) => league.league_id === defaultLeagueId)
      || leagues[0] || null;
    const leagueId = selectedLeague?.league_id || defaultLeagueId;
    if (selectedLeague) localStorage.setItem('mirrorball-active-league', leagueId);
    if (selectedLeague && selectedLeague.league_id !== defaultLeagueId) {
      currentMember = { fantasy_team_id: selectedLeague.fantasy_team_id,
        is_commissioner: selectedLeague.member_role === 'owner' };
      teamName = selectedLeague.team_name || '';
    }
    const legacyName = [currentMember?.first_name, currentMember?.last_name].filter(Boolean).join(' ') || metadata.display_name || metadata.full_name || metadata.name || '';
    const displayName = currentProfile?.display_name || legacyName;
    const [firstName = '', ...remainingNames] = displayName.trim().split(/\s+/).filter(Boolean);
    const lastName = remainingNames.join(' ');
    if (!teamName && currentMember?.fantasy_team_id) {
      const { data: team } = await db.from('fantasy_teams').select('team_name')
        .eq('league_id', leagueId).eq('id', currentMember.fantasy_team_id).maybeSingle();
      if (version !== accessVersion) return;
      teamName = team?.team_name || '';
    }
    const isCommissioner = selectedLeague ? selectedLeague.member_role === 'owner' : Boolean(currentMember?.is_commissioner);
    auth.replaceChildren();
    if (signedInEmail && currentProfile?.avatar_url) {
      const image = document.createElement('img');
      image.src = currentProfile.avatar_url;
      image.alt = '';
      image.className = 'account-button-picture';
      auth.append(image);
    }
    auth.append(document.createTextNode(signedInEmail ? firstName || displayName || 'Signed in' : 'Sign in'));
    email.textContent = signedInEmail || '';
    usernameInput.value = currentProfile?.username || '';
    displayNameInput.value = displayName;
    document.querySelector('#accountUsernameText').textContent = currentProfile?.username ? `@${currentProfile.username}` : 'Username not set';
    document.querySelector('#accountDisplayNameText').textContent = displayName || 'Set up your profile';
    releasePreview();
    pendingPicture = null;
    pictureDirty = false;
    profileEditing = currentProfile?.onboarding_completed === false;
    profileCancel.hidden = profileEditing;
    pictureFile.value = '';
    selectedAvatarUrl = currentProfile?.avatar_url || '';
    updatePicturePreview(selectedAvatarUrl, displayName);
    pictureOptions.hidden = true;
    pictureButton.setAttribute('aria-expanded', 'false');
    syncProfileControls();
    profileHint.hidden = currentProfile?.onboarding_completed !== false;
    myLeaguesNav.hidden = true;
    const labelMode = currentMember?.team_nav_label_mode || 'default';
    const teamNavLabel = selectedLeague?.league_id !== defaultLeagueId && ['setup', 'drafting'].includes(selectedLeague?.status) ? 'Draft'
      : labelMode === 'custom' && currentMember?.custom_team_nav_label
      ? currentMember.custom_team_nav_label
      : labelMode === 'team' && teamName ? teamName : 'My Team';
    myTeamNav.querySelector('.nav-label').textContent = teamNavLabel;
    myTeamNav.setAttribute('aria-label', teamNavLabel);
    myTeamNav.hidden = !signedInEmail || (membershipReady && !currentMember?.fantasy_team_id);
    const dancesNav = buttons.find((button) => button.dataset.view === 'score');
    dancesNav.hidden = selectedLeague?.league_id !== defaultLeagueId && ['setup', 'drafting'].includes(selectedLeague?.status);
    scoreDeskLink.hidden = !isPlatformAdmin;
    castRosterLink.hidden = !isPlatformAdmin;
    if ((requestedView === 'teams' && myTeamNav.hidden) || (requestedView === 'score' && dancesNav.hidden)) openView('standings', false);
    else openView(requestedView, false);
    if (previousUserId !== session?.user?.id) menu.hidden = currentProfile?.onboarding_completed !== false;
    auth.setAttribute('aria-expanded', String(!menu.hidden));
    providerLinks.hidden = !session?.user;
    if (session?.user) {
      const identitiesResult = await db.auth.getUserIdentities();
      if (version !== accessVersion) return;
      const providers = new Set((identitiesResult.data?.identities || []).map((identity) => identity.provider));
      for (const provider of ['google', 'apple']) {
        const button = document.querySelector(`#connect${provider === 'google' ? 'Google' : 'Apple'}`);
        button.textContent = providers.has(provider) ? `${provider === 'google' ? 'Google' : 'Apple'} connected` : `Connect ${provider === 'google' ? 'Google' : 'Apple'}`;
        button.disabled = providers.has(provider);
      }
    }
    currentAccessDetail = { signedIn: Boolean(signedInEmail), userId: session?.user?.id || null, email: signedInEmail, firstName, lastName, displayName, username: currentProfile?.username || '', avatarUrl: currentProfile?.avatar_url || '', onboardingCompleted: currentProfile?.onboarding_completed === true, teamName, teamNavLabelMode: labelMode, customTeamNavLabel: currentMember?.custom_team_nav_label || '', isCommissioner, isPlatformAdmin, fantasyTeamId: selectedLeague?.fantasy_team_id || currentMember?.fantasy_team_id || null, membershipReady, leagueId, leagueName: selectedLeague?.name || 'DWTS Fantasy League', leagueStatus: selectedLeague?.status || 'active', rosterSize: selectedLeague?.roster_size || 11, leagueRole: selectedLeague?.member_role || null, scoringStartsAfterWeek: selectedLeague?.scoring_starts_after_week || 0, leagues, leaguesError, joinToken };
    window.dispatchEvent(new CustomEvent('mirrorball-auth-change', { detail: currentAccessDetail }));
  }

  window.addEventListener('hashchange', () => {
    const view = location.hash.slice(1);
    if (rememberedViews.has(view)) {
      requestedView = view;
      if ((view !== 'teams' || !myTeamNav.hidden) && (view !== 'score' || !buttons.find((button) => button.dataset.view === 'score').hidden)) openView(view, false);
    }
  });
  db.auth.onAuthStateChange((event, nextSession) => {
    if (event === 'TOKEN_REFRESHED' || (event === 'SIGNED_IN' && currentSession?.user?.id === nextSession?.user?.id)) {
      currentSession = nextSession;
      return;
    }
    queueMicrotask(() => showAccess(nextSession));
  });

  auth.addEventListener('click', () => {
    const signedIn = currentAccessDetail?.signedIn === true;
    if (!signedIn) return openView('signin');
    menu.hidden = !menu.hidden;
    auth.setAttribute('aria-expanded', String(!menu.hidden));
    if (!menu.hidden && currentAccessDetail) {
      window.dispatchEvent(new CustomEvent('mirrorball-account-open', { detail: currentAccessDetail }));
    }
  });
  document.addEventListener('click', (event) => {
    if (!menu.hidden && !document.querySelector('#modal').open && !event.target.closest('.account')) {
      menu.hidden = true;
      auth.setAttribute('aria-expanded', 'false');
    }
  });
  document.querySelector('#saveAccountProfile').addEventListener('click', async () => {
    const button = document.querySelector('#saveAccountProfile');
    const username = usernameInput.value.trim().toLowerCase();
    const displayName = displayNameInput.value.trim();
    let avatarUrl = selectedAvatarUrl;
    usernameInput.value = username;
    if (!/^[a-z0-9_]{3,20}$/.test(username)) return alert('Username must be 3–20 characters using lowercase letters, numbers, or underscores.');
    if (!displayName || displayName.length > 80) return alert('Enter a display name of 80 characters or fewer.');
    button.disabled = true;
    button.textContent = 'Saving…';
    if (pendingPicture) {
      const extension = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }[pendingPicture.type];
      const path = `${currentSession.user.id}/${crypto.randomUUID()}.${extension}`;
      const upload = await db.storage.from('profile-pictures').upload(path, pendingPicture, {
        contentType: pendingPicture.type, upsert: false,
      });
      if (upload.error) {
        button.disabled = false;
        button.textContent = 'Save changes';
        return alert('Couldn’t upload your picture. Please try again.');
      }
      avatarUrl = db.storage.from('profile-pictures').getPublicUrl(path).data.publicUrl;
    }
    const { error } = await db.rpc('update_my_profile', { p_username: username, p_display_name: displayName, p_avatar_url: avatarUrl || null });
    button.disabled = false;
    button.textContent = 'Save changes';
    if (error) return alert(error.message.includes('already taken') ? 'That username is already taken.' : `Couldn’t save your profile: ${error.message}`);
    await showAccess(currentSession);
    menu.hidden = false;
    auth.setAttribute('aria-expanded', 'true');
  });
  document.querySelector('#magic').addEventListener('click', async () => {
    const button = document.querySelector('#magic');
    button.disabled = true; button.textContent = 'Signing in…';
    const { error } = await db.auth.signInWithPassword({ email: document.querySelector('#email').value.trim(), password: document.querySelector('#password').value });
    button.disabled = false; button.textContent = 'Sign in with email';
    if (error) return alert(error.message);
    openView('standings');
  });
  for (const provider of ['google', 'apple']) {
    const label = provider === 'google' ? 'Google' : 'Apple';
    const redirectTo = `${location.origin}${location.pathname}${location.search}`;
    document.querySelector(`#signIn${label}`).addEventListener('click', async () => {
      const button = document.querySelector(`#signIn${label}`);
      button.disabled = true;
      const { error } = await db.auth.signInWithOAuth({ provider, options: { redirectTo } });
      if (error) {
        button.disabled = false;
        document.querySelector('#signInMessage').textContent = `Couldn’t continue with ${label}: ${error.message}`;
      }
    });
    document.querySelector(`#connect${label}`).addEventListener('click', async () => {
      const button = document.querySelector(`#connect${label}`);
      button.disabled = true;
      const { error } = await db.auth.linkIdentity({ provider, options: { redirectTo } });
      if (error) {
        button.disabled = false;
        document.querySelector('#providerLinkMessage').textContent = `Couldn’t connect ${label}: ${error.message}. Check that manual identity linking is enabled in Supabase.`;
      }
    });
  }
  document.querySelector('#signOut').addEventListener('click', async () => { await db.auth.signOut(); });
  const { data: { session } } = await db.auth.getSession();
  await showAccess(session);
});
