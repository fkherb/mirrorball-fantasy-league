import { db } from './supabase-client.js?v=20260930-avatar-frame-v78';
import { episodeSpotlight, standingsSwitch, standingCard, scoreRows, overviewTeamDetail, highlightCards, teamCard, teamDetail, castRosterRow, castThumbnailFor, judgePortraitFor, danceCard, fitDanceCardNames, fitDanceSongLabels, teamPage, roleRatesTable, castProfile, danceDetail, bindDanceGallery, bindCastPredictionToggle } from './postdraft-view.js?v=20260930-avatar-frame-v78';
import { danceImagesFor, danceCardPhotoFor } from './dance-images.js?v=20260930-avatar-frame-v78';
import { loadMarketPredictions } from './market-predictions.js?v=20260930-avatar-frame-v78';
import { activePartnershipPredictionRows, nextPredictionWeek, seasonPredictionsFor, weeklyPredictionFor } from './market-prediction-model.js?v=20260930-avatar-frame-v78';
import { isDraftAiringLocked, isTradeAiringLocked } from './week-airing-policy.js?v=20260930-avatar-frame-v78';
import { scoreLeague } from './scoring.js?v=20260930-avatar-frame-v78';

const $ = (selector) => document.querySelector(selector);
const safe = (value = '') => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const defaultLeagueId = '00000000-0000-4000-8000-000000000001';
let workspaceVersion = 0;
let workspaceRefreshTimer = null;
let workspaceDraftTimer = null;
let refreshCurrentWorkspaceDraft = null;
let workspaceDraftPollInFlight = false;
let selectedDraftRound = null;
let draftPoolFilter = 'All';
const draftPositionExpanded = new Map();
const draftPositionCounts = new Map();
let selectedTeamWeekId = 'all';
let workspaceTradeRefreshTimer = null;
let refreshCurrentWorkspaceTrades = null;
let tradeRequestVersion = 0;
let hubVersion = 0;
let workspaceActionPending = false;
let selectedDanceWeekId = null;
let danceSongResizeObserver = null;
let tradeTab = 'active';
let workspaceRosterFilter = 'all';
let selectedWorkspaceOverviewTeamId = null;
let workspaceStandingsMode = 'season';
let activeWorkspaceDetail = null;
let lastFullWorkspaceLoadAt = 0;
let lastSnapshotCheckAt = 0;
let lastSnapshotLeagueId = null;
const fullWorkspaceRefreshMs = 2 * 60 * 1000;
const snapshotCheckMs = 5 * 60 * 1000;
const fastWorkspaceKeys = new Set(['league', 'assignments', 'weeks', 'dances', 'scores', 'appearances']);

function dialog(markup) {
  const modal = $('#modal');
  $('#modalBody').innerHTML = `<div class="modal">${markup}</div>`;
  modal.dataset.dirty = 'false';
  $('#modalClose').onclick = () => modal.close();
  modal.oncancel = null;
  if (!modal.open) modal.showModal();
  modal.scrollTop = 0;
  $('#modalBody').scrollTop = 0;
}

function errorMessage(error, fallback = 'Please try again.') {
  console.error(error);
  return error?.code === 'P0001' && error.message ? error.message : fallback;
}

function leagueUrl(leagueId, view = 'standings') {
  const url = new URL(location.href);
  url.searchParams.set('league', leagueId);
  url.searchParams.delete('join');
  url.hash = `#${view}`;
  return url.toString();
}

function castImage(member) {
  const stored = member?.image_path;
  if (stored && /^(?:https?:|data:|\/)/i.test(stored)) return stored;
  return stored ? stored.replace(/^\.\//, '') : `Images/${String(member?.name || '').replace(/[.,'’]/g, '')}.jpg`;
}

function castTile(member, action = '', tag = 'article', profileButton = false) {
  const image = castImage(member);
  const identity = `<img src="${safe(castThumbnailFor(image))}" data-original-src="${safe(image)}" alt="" loading="lazy" decoding="async" width="70" height="80"><span><b>${safe(member.name)}</b><small>${safe(member.role === 'DWTS Next Pro' ? 'Next Pro' : member.role)}</small></span>`;
  return `<${tag} class="workspace-cast-tile">${profileButton ? `<button type="button" class="workspace-profile-button" data-workspace-profile="${safe(member.id)}" aria-label="View ${safe(member.name)} profile and points">${identity}</button>` : identity}${action}</${tag}>`;
}

function projectedDraftCastPoints(cast, data, score) {
  const completedWeeks = new Map(data.weeks.filter((week) => week.is_complete)
    .map((week) => [week.id, week]));
  const dances = new Map(data.dances.filter((dance) => completedWeeks.has(dance.week_id))
    .map((dance) => [dance.id, dance]));
  const pairs = new Map(data.pairs.map((pair) => [pair.id, pair]));
  let judgesTotal = 0;
  let appearanceCount = 0;
  let appearancePoints = 0;
  for (const dance of dances.values()) {
    const pair = pairs.get(dance.partnership_id);
    if (dance.kind === 'competitive' && (pair?.star_id === cast.id || pair?.pro_id === cast.id)) {
      judgesTotal += score.scoreByDance.get(dance.id) || 0;
    }
  }
  for (const appearance of data.appearances) {
    if (appearance.cast_member_id !== cast.id) continue;
    const dance = dances.get(appearance.dance_id);
    if (!dance) continue;
    appearanceCount += 1;
    const eliminationWeek = cast.eliminated_week_id && data.weeks.find((week) => week.id === cast.eliminated_week_id);
    const beforeElimination = eliminationWeek && completedWeeks.get(dance.week_id)?.number <= eliminationWeek.number;
    const role = beforeElimination && cast.role === 'Eliminated Star' ? 'Star'
      : beforeElimination && cast.role === 'Eliminated Pro' ? 'Pro' : cast.role;
    const rate = cast.is_hough ? score.rateByName.get('Hough')
      : role === 'Surprise' ? cast.surprise_base_role
        ? (score.rateByName.get(cast.surprise_base_role) || 0) + 2 : cast.custom_appearance_points
        : score.rateByName.get(role);
    appearancePoints += Number(rate) || 0;
  }
  return { judgesTotal, appearanceCount, fantasyPoints: judgesTotal + appearancePoints };
}

function openWorkspaceCastProfile(cast, teamName = 'Available cast', backAction = null, backLabel = 'team') {
  if (!cast) return;
  const state = activeWorkspaceDetail;
  const teamId = state?.assignmentMap.get(cast.id);
  const team = state?.data.teams.find((item) => item.id === teamId);
  const teamMember = state?.memberByTeam.get(teamId);
  const managerName = teamMember?.display_name || team?.manager_name || 'Manager';
  const currentTeamName = team?.team_name || teamMember?.team_name || (team ? `${managerName.split(' ')[0]}'s Team` : teamName);
  const pair = state?.data.pairs.find((item) => item.active && (item.star_id === cast.id || item.pro_id === cast.id))
    || (cast.role?.startsWith('Eliminated')
      ? state?.data.pairs.find((item) => item.star_id === cast.id || item.pro_id === cast.id) : null);
  const partnerId = pair?.star_id === cast.id ? pair.pro_id : pair?.star_id;
  const partner = state?.data.cast.find((item) => item.id === partnerId);
  const activePair = pair?.active && ['Star', 'Pro'].includes(cast.role) && partner && ['Star', 'Pro'].includes(partner.role);
  const linkedPartner = partner && ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro'].includes(partner.role);
  const predictionStarId = activePair ? pair.star_id : null;
  const predictionWeek = nextPredictionWeek(state?.data.weeks || []);
  const showWeeklyPrediction = Boolean(activePair && predictionWeek && !predictionWeek.is_complete && !predictionWeek.is_finale);
  const weeklyDance = showWeeklyPrediction ? state.data.dances.find((dance) => dance.week_id === predictionWeek.id
    && dance.partnership_id === pair.id && dance.kind === 'competitive') : null;
  const activePredictions = activePartnershipPredictionRows(state?.predictions || [], state?.data.pairs, state?.data.cast);
  const partnerTeamId = state?.assignmentMap.get(partner?.id);
  const partnerTeam = state?.memberByTeam.get(partnerTeamId);
  const draftPreview = state?.context.leagueStatus === 'setup' || state?.context.leagueStatus === 'drafting';
  const scoringWeeks = new Set(state?.score.scoringWeeks.map((week) => week.id) || []);
  const totals = [...(state?.score.pointsByWeekCast || new Map())].reduce((sum, [key, value]) => {
    if (!key.endsWith(`:${cast.id}`)) return sum;
    sum.official += value.official || 0;
    sum.appearances += value.appearances || 0;
    return sum;
  }, { official: 0, appearances: 0 });
  const appearanceCount = state?.data.appearances.filter((appearance) => {
    if (appearance.cast_member_id !== cast.id) return false;
    const weekId = state.data.dances.find((dance) => dance.id === appearance.dance_id)?.week_id;
    return scoringWeeks.has(weekId) && state.score.snapshotByKey.get(`${weekId}:${cast.id}`)?.fantasy_team_id;
  }).length || 0;
  const projected = draftPreview ? projectedDraftCastPoints(cast, state.data, state.score) : null;
  dialog(castProfile({ member: cast, image: castImage(cast),
    role: cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role, teamName: currentTeamName,
    partnershipName: pair?.partnership_name || '',
    teamId, teamAvatar: teamMember?.avatar_url || '',
    fantasyPoints: projected?.fantasyPoints ?? totals.official + totals.appearances,
    judgesTotal: projected?.judgesTotal ?? totals.official,
    appearanceCount: projected?.appearanceCount ?? appearanceCount,
    pointsLabel: draftPreview ? 'Projected fantasy points' : 'Fantasy points',
    pointsNote: draftPreview ? 'From completed shows and this league’s current appearance rates. These are a draft preview, not points earned by a team.' : '',
    showJudges: ['Star', 'Pro', 'Eliminated Star', 'Eliminated Pro'].includes(cast.role),
    showWins: ['Pro', 'Eliminated Pro'].includes(cast.role) || (cast.role === 'Judges + Hosts' && cast.is_hough),
    details: cast.profile_details && typeof cast.profile_details === 'object'
      ? Object.entries(cast.profile_details).filter(([key, value]) => !key.startsWith('_') && value) : [],
    backLabel: backAction ? backLabel : '',
    partnerMember: linkedPartner ? partner : null, partnerImage: linkedPartner ? castImage(partner) : '',
    seasonPredictions: seasonPredictionsFor(predictionStarId, activePredictions),
    weeklyPrediction: weeklyPredictionFor(predictionStarId, predictionWeek, activePredictions),
    predictionWeekNumber: predictionWeek?.number, showWeeklyPrediction, weeklyDanceId: weeklyDance?.id || '' }));
  bindCastPredictionToggle($('#modalBody'));
  document.querySelectorAll('#modalBody [data-weekly-dance-detail]').forEach((button) => button.addEventListener('click', () => {
    if (weeklyDance) openWorkspaceDanceDetail(state.data, state.score, state.assignmentMap,
      state.memberByTeam, predictionWeek, weeklyDance,
      () => openWorkspaceCastProfile(cast, teamName, backAction, backLabel));
  }));
  $('#profileBack')?.addEventListener('click', backAction);
  document.querySelectorAll('#modalBody [data-partner-profile]').forEach((button) => button.addEventListener('click', () => openWorkspaceCastProfile(partner,
    partnerTeam?.team_name || partnerTeam?.display_name || 'Available cast',
    () => openWorkspaceCastProfile(cast, teamName, backAction, backLabel), 'profile')));
  document.querySelectorAll('#modalBody [data-cast-team-detail]').forEach((button) => button.addEventListener('click', () => openWorkspaceTeamDetail(teamId,
    () => openWorkspaceCastProfile(cast, teamName, backAction, backLabel))));
}

function openWorkspaceTeamDetail(teamId, backAction = null) {
  const state = activeWorkspaceDetail;
  const team = state?.data.teams.find((item) => item.id === teamId);
  if (!team) return;
  const managerName = state.memberByTeam.get(team.id)?.display_name || team.manager_name;
  const name = team.team_name || `${managerName.split(' ')[0]}'s Team`;
  const roster = state.data.cast.filter((cast) => state.assignmentMap.get(cast.id) === team.id);
  dialog(teamDetail({ manager: managerName, name,
    roster: roster.map((cast) => ({ ...cast, displayRole: cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role })),
    imageFor: castImage, backLabel: backAction ? 'profile' : '' }));
  $('#teamProfileBack')?.addEventListener('click', backAction);
  $('#modalBody').querySelectorAll('[data-team-cast-detail]').forEach((tile) => {
    const show = () => openWorkspaceCastProfile(state.data.cast.find((cast) => cast.id === tile.dataset.teamCastDetail),
      name, () => openWorkspaceTeamDetail(teamId, backAction), 'team');
    tile.addEventListener('click', show);
    tile.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); show(); } });
  });
}

async function runAction(action, success, button = document.activeElement) {
  if (activeWorkspaceDetail?.context.readOnlyWorkspacePreview) {
    dialog('<h2>Preview only</h2><p>This preview cannot change rosters, trades, or league settings. Open the regular league page to manage your team.</p>');
    return;
  }
  if (workspaceActionPending) return;
  if (!(button instanceof HTMLButtonElement)) button = null;
  workspaceActionPending = true;
  if (button) {
    button.disabled = true;
    button.setAttribute('aria-busy', 'true');
  }
  try {
    const { error } = await action();
    if (error) throw error;
    if (success) await success();
  } catch (error) {
    dialog(`<h2>Couldn’t complete that action</h2><p>${safe(errorMessage(error))}</p>`);
  } finally {
    workspaceActionPending = false;
    if (button?.isConnected) {
      button.disabled = false;
      button.removeAttribute('aria-busy');
    }
  }
}

async function completeProfileIfNeeded(context) {
  if (context.onboardingCompleted) return { error: null };
  if (typeof window.mirrorballSaveProfile !== 'function') {
    return { error: new Error('Save your profile before continuing.') };
  }
  return window.mirrorballSaveProfile();
}

function inviteRows(invites, context, membershipLimitReached) {
  return invites.map((invite) => `<article class="workspace-invite-row"><span class="workspace-invite-mark" aria-hidden="true">${safe(invite.league_name.charAt(0).toUpperCase())}</span><div class="workspace-invite-copy"><b>${safe(invite.league_name)}</b><small>${invite.linkToken ? 'Shared invite link' : `Invited by @${safe(invite.inviter_username)}`}</small></div><div class="workspace-invite-actions"><button ${invite.linkToken ? `data-link-accept="${safe(invite.linkToken)}" data-link-league="${safe(invite.league_id)}"` : `data-invite-accept="${safe(invite.id)}"`} ${membershipLimitReached || context.leaguesError ? 'disabled' : ''}>Join</button><button class="secondary" ${invite.linkToken ? 'data-link-decline' : `data-invite-decline="${safe(invite.id)}"`}>Decline</button></div></article>`).join('');
}

function storedLinkKey(userId) {
  return `mirrorball-pending-link-invite-${userId}`;
}

function clearStoredLink(context) {
  sessionStorage.removeItem('mirrorball-guest-link-invite');
  if (context.userId) localStorage.removeItem(storedLinkKey(context.userId));
}

function bindInviteActions(scope, context) {
  scope.querySelectorAll('[data-invite-accept], [data-invite-decline], [data-link-accept], [data-link-decline]').forEach((button) => {
    if (button.hasAttribute('data-link-decline')) {
      button.addEventListener('click', () => {
        clearStoredLink(context);
        const url = new URL(location.href);
        url.searchParams.delete('join');
        location.assign(url.toString());
      });
      return;
    }
    button.addEventListener('click', () => runAction(
      async () => {
        if (button.dataset.inviteAccept || button.dataset.linkAccept) {
          const profile = await completeProfileIfNeeded(context);
          if (profile.error) return profile;
        }
        if (button.dataset.linkAccept) return db.rpc('join_league_with_link', { p_token: button.dataset.linkAccept });
        return db.rpc('respond_to_league_invite', {
          p_invite_id: button.dataset.inviteAccept || button.dataset.inviteDecline,
          p_accept: Boolean(button.dataset.inviteAccept),
        });
      },
      async () => {
        if (button.dataset.linkAccept) {
          clearStoredLink(context);
          location.assign(leagueUrl(button.dataset.linkLeague));
        }
        else location.reload();
      },
      button,
    ));
  });
}

async function redeemInviteCode(context, code, button, message) {
  button.disabled = true;
  message.textContent = 'Checking invitation…';
  try {
    const profile = await completeProfileIfNeeded(context);
    if (profile.error) throw profile.error;
    const { data, error } = await db.rpc('join_league_with_code', { p_code: code });
    if (error) throw error;
    if (data?.status === 'rate_limited') message.textContent = 'Too many attempts. Please try again in an hour or use the invite link.';
    else if (data?.status !== 'joined') message.textContent = 'That code is invalid or expired. Check it with the person who invited you.';
    else {
      location.assign(leagueUrl(data.league_id));
    }
  } catch (error) {
    message.textContent = errorMessage(error);
  } finally { button.disabled = false; }
}

function inviteCodeBoxes(prefix) {
  return `<div class="workspace-code-boxes" role="group" aria-label="Six-character invite code">${Array.from({ length: 6 }, (_, index) => `<input id="${prefix}${index}" type="text" maxlength="1" inputmode="text" autocomplete="off" autocapitalize="characters" spellcheck="false" aria-label="Character ${index + 1} of 6">`).join('')}</div>`;
}

function bindInviteCodeBoxes(prefix, initialCode = '') {
  const boxes = Array.from({ length: 6 }, (_, index) => $(`#${prefix}${index}`));
  if (boxes.some((box) => !box)) return { get: () => '', set: () => {} };
  const set = (value) => {
    const characters = String(value || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6);
    boxes.forEach((box, index) => { box.value = characters[index] || ''; });
    boxes[Math.min(characters.length, 5)].focus();
  };
  if (initialCode) set(initialCode);
  boxes.forEach((box, index) => {
    box.addEventListener('input', () => {
      const characters = box.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
      if (characters.length > 1) { set(characters); return; }
      box.value = characters;
      if (characters && index < 5) boxes[index + 1].focus();
    });
    box.addEventListener('keydown', (event) => {
      if (event.key === 'Backspace' && !box.value && index > 0) boxes[index - 1].focus();
      if (event.key === 'ArrowLeft' && index > 0) boxes[index - 1].focus();
      if (event.key === 'ArrowRight' && index < 5) boxes[index + 1].focus();
    });
    box.addEventListener('paste', (event) => {
      const pasted = event.clipboardData?.getData('text') || '';
      if (!pasted) return;
      event.preventDefault();
      set(pasted);
    });
    box.addEventListener('focus', () => box.select());
  });
  return { get: () => boxes.map((box) => box.value).join('').toUpperCase(), set };
}

function openInviteCodeDialog(context) {
  if (!context.signedIn) return;
  dialog(`<p class="eyebrow">League invitation</p><h2>Enter invite code</h2><p class="sub">Use the six-character code from your friend’s invitation.</p><form id="accountInviteCodeForm" class="workspace-code-form" novalidate><label>Invite code</label>${inviteCodeBoxes('accountCodeBox')}<button id="accountInviteCodeSubmit" type="submit">Join league</button><p id="accountInviteCodeMessage" class="sub" role="status"></p></form>`);
  const controls = bindInviteCodeBoxes('accountCodeBox');
  $('#accountInviteCodeForm').onsubmit = async (event) => {
    event.preventDefault();
    const code = controls.get();
    if (code.length !== 6) {
      $('#accountInviteCodeMessage').textContent = 'Enter all six characters from your invitation.';
      return;
    }
    await redeemInviteCode(context, code, $('#accountInviteCodeSubmit'), $('#accountInviteCodeMessage'));
  };
}

function renderWelcomeActions(context, invites, invitesError) {
  const getStarted = $('#welcomeGetStarted');
  const inviteButton = $('#welcomeInvites');
  const shareButton = $('#welcomeShare');
  const status = $('#welcomeStatus');
  const firstStep = $('#signedOutOverview .welcome-steps article p');
  if (!getStarted || !inviteButton || !shareButton || !status) return;
  const noLeague = context.noLeague;
  if (firstStep) firstStep.textContent = noLeague
    ? 'Create a league or accept an invitation from a friend. Then get ready to draft together.'
    : 'Continue with Google or Apple, choose a username, then invite friends to your league.';
  getStarted.textContent = noLeague ? context.leaguesError ? 'Try again' : 'Create league' : 'Create an account or sign in';
  inviteButton.hidden = !noLeague;
  shareButton.hidden = !noLeague;
  inviteButton.innerHTML = `Manage invites${context.leaguesError || invitesError ? '' : invites.length ? ` <span class="invite-notification-count">${invites.length}</span>` : ''}`;
  status.hidden = !noLeague;
  status.textContent = noLeague ? context.leaguesError ? 'We couldn’t load your leagues. Please try again.' : 'Already invited? Check your invitations. Or create a league to get started.' : '';
  inviteButton.onclick = () => {
    dialog(`<div class="welcome-invite-dialog"><p class="eyebrow">Your invitations</p><h2>League invites</h2><p class="sub">Join a league to start drafting with friends.</p>${invitesError ? '<div class="welcome-empty-invites"><b>Couldn’t load invitations</b><p>Refresh the page to try again.</p></div>' : invites.length ? `<div class="workspace-invite-list">${inviteRows(invites, context, false)}</div>` : '<div class="welcome-empty-invites"><b>No invitations yet</b><p>Ask a friend to invite you by username or send you a league link.</p></div>'}<button id="welcomeEnterInviteCode" type="button" class="secondary">Enter invite code</button></div>`);
    bindInviteActions($('#modalBody'), context);
    $('#welcomeEnterInviteCode').onclick = () => openInviteCodeDialog(context);
  };
  shareButton.onclick = async () => {
    if (!context.username) {
      dialog('<h2>Set your username first</h2><p>Choose a username in your profile before sharing it with friends.</p>');
      return;
    }
    const siteUrl = new URL('./', location.href).toString();
    const message = `Come join me on Dancing with the Stars Fantasy League! ${siteUrl} Find me @${context.username}.`;
    if (/iPhone|iPad|iPod/i.test(navigator.userAgent) && navigator.share) {
      try { await navigator.share({ text: message }); } catch (error) {
        if (error.name !== 'AbortError') console.error(error);
      }
    } else location.href = `sms:?body=${encodeURIComponent(message)}`;
  };
}

export async function renderLeagueHub(context) {
  const version = ++hubVersion;
  const container = $('#leagueHubContent');
  const joinBanner = $('#joinInviteBanner');
  if (!container || !joinBanner) return;
  const leagues = context.leagues || [];
  const signedIn = context.signedIn;
  const membershipLimitReached = leagues.length >= 5;
  let invites = [];
  let invitesError = false;
  if (signedIn) {
    const result = await db.rpc('get_my_league_invites');
    if (version !== hubVersion) return;
    if (!result.error) invites = result.data || [];
    else { invitesError = true; console.error(result.error); }
  }
  const token = context.joinToken || (signedIn
    ? localStorage.getItem(storedLinkKey(context.userId)) || sessionStorage.getItem('mirrorball-guest-link-invite')
    : sessionStorage.getItem('mirrorball-guest-link-invite'));
  let linkInvite = null;
  if (token) {
    if (signedIn) {
      localStorage.setItem(storedLinkKey(context.userId), token);
      sessionStorage.removeItem('mirrorball-guest-link-invite');
    } else sessionStorage.setItem('mirrorball-guest-link-invite', token);
    const preview = await db.rpc('preview_league_invite_link', { p_token: token });
    if (version !== hubVersion) return;
    const league = preview.data?.[0];
    if (signedIn && league && !leagues.some((item) => item.league_id === league.league_id)) {
      linkInvite = { league_id: league.league_id, league_name: league.league_name, linkToken: token };
    }
    if (!league || signedIn && !linkInvite) clearStoredLink(context);
    joinBanner.innerHTML = signedIn ? '' : league
      ? `<div class="card pad workspace-invite-banner"><span class="workspace-invite-mark" aria-hidden="true">${safe(league.league_name.charAt(0).toUpperCase())}</span><div><p class="eyebrow">League invitation</p><h2>${safe(league.league_name)}</h2><p class="sub">Sign in or create an account to respond to this invitation.</p><div class="workspace-invite-banner-actions"><button id="joinSignIn" type="button">Sign in</button><button id="joinSignUp" type="button" class="secondary">Create account</button></div></div></div>`
      : '<div class="card pad workspace-invite-banner"><div><p class="eyebrow">League invitation</p><h2>Link unavailable</h2><p class="sub">This invitation has expired or was replaced. Ask the league commissioner for a new link or code.</p></div></div>';
    ['#joinSignIn', '#joinSignUp'].forEach((selector) => $(selector)?.addEventListener('click', () => $('#auth')?.click()));
  } else joinBanner.innerHTML = '';

  const visibleInvites = linkInvite && !invites.some((invite) => invite.league_id === linkInvite.league_id)
    ? [linkInvite, ...invites] : invites;
  renderWelcomeActions(context, visibleInvites, invitesError);
  const accountBadge = $('#auth .invite-notification-count');
  accountBadge?.remove();
  if (signedIn && visibleInvites.length) {
    $('#auth')?.insertAdjacentHTML('beforeend', `<span class="invite-notification-count" aria-label="${visibleInvites.length} pending invitations">${visibleInvites.length}</span>`);
  }

  if (!signedIn) {
    container.innerHTML = '';
    return;
  }
  const ownedCount = leagues.filter((league) => league.member_role === 'owner' && league.league_id !== defaultLeagueId).length;
  const createDisabled = context.leaguesError || membershipLimitReached || ownedCount >= 2;
  const onboarding = !context.onboardingCompleted
    ? '<p class="account-league-note">Your profile details will be saved when you join or create a league.</p>' : '';
  container.innerHTML = `${onboarding}<div class="workspace-section-head"><h2>Your leagues</h2><button id="createLeagueButton" type="button" ${createDisabled ? 'disabled' : ''}>Create</button></div>${context.leaguesError ? '<p class="account-league-note">Couldn’t load your leagues. Refresh to try again.</p><button id="retryAccountLeagues" type="button">Try again</button>' : `<div class="workspace-league-list">${leagues.map((league) => `<a class="workspace-league-link ${league.league_id === context.leagueId ? 'current' : ''}" href="${safe(leagueUrl(league.league_id))}" ${league.league_id === context.leagueId ? 'aria-current="page"' : ''}><span><b>${safe(league.name)}</b><small>${league.status === 'setup' ? 'Setting up' : league.status === 'drafting' ? 'Draft in progress' : 'Season in progress'} · ${safe(league.member_role)}</small></span><span aria-hidden="true">›</span></a>`).join('') || '<p class="account-league-note">No leagues yet. Create one to invite friends.</p>'}</div><p class="account-league-limits">${leagues.length} of 5 joined · ${ownedCount} of 2 created</p>`}<button id="enterLeagueInviteCode" type="button" class="secondary" ${context.leaguesError || membershipLimitReached ? 'disabled' : ''}>Enter invite code</button>${visibleInvites.length ? `<section class="workspace-invites-mini"><div class="workspace-inbox-head"><h2>Invitations</h2><span>${visibleInvites.length}</span></div><div class="workspace-invite-list">${inviteRows(visibleInvites, context, membershipLimitReached)}</div></section>` : ''}`;
  $('#retryAccountLeagues')?.addEventListener('click', () => location.reload());
  $('#enterLeagueInviteCode')?.addEventListener('click', () => openInviteCodeDialog(context));
  $('#createLeagueButton')?.addEventListener('click', () => {
    dialog('<div class="workspace-create-league"><p class="eyebrow">New league</p><h2>Create a League</h2><p class="sub">Start a private league, then invite your friends.</p><label>League name<input id="newLeagueName" maxlength="80" placeholder="e.g. Saturday Night League"></label><div class="workspace-create-facts"><span><b>3–5 managers</b><small>Invite friends after creating</small></span><span><b>Auto-sized rosters</b><small>3: 12 · 4: 10 · 5: 8 cast per team</small></span></div><div class="modal-actions"><button id="confirmCreateLeague">Create league</button></div></div>');
    $('#confirmCreateLeague').addEventListener('click', () => {
      let createdId;
      runAction(async () => {
        const profile = await completeProfileIfNeeded(context);
        if (profile.error) return profile;
        const result = await db.rpc('create_fantasy_league', { p_name: $('#newLeagueName').value.trim() });
        createdId = result.data;
        return result;
      }, async () => location.assign(leagueUrl(createdId)), $('#confirmCreateLeague'));
    });
  });
  bindInviteActions(container, context);
}

function draftTurn(order, picks, rosterSize) {
  if (!order.length || picks.length >= order.length * rosterSize) return null;
  const round = Math.floor(picks.length / order.length) + 1;
  const slot = picks.length % order.length;
  return { round, teamId: order[round % 2 ? slot : order.length - slot - 1].fantasy_team_id,
    pickNumber: picks.length + 1 };
}

function castCategory(member) {
  return member.role === 'Pro' || member.role === 'Star' ? member.role : 'Bonus';
}

function draftPositionBoard(roster, picks, proLimit, starLimit, bonusLimit, flexLimit, leagueId) {
  const pickOrder = new Map(picks.map((pick) => [pick.cast_member_id, pick.pick_number]));
  const ordered = [...roster].sort((a, b) => (pickOrder.get(a.id) || Infinity) - (pickOrder.get(b.id) || Infinity));
  const byCategory = (category) => ordered.filter((member) => castCategory(member) === category);
  const pros = byCategory('Pro');
  const stars = byCategory('Star');
  const bonus = byCategory('Bonus');
  const overflow = [...pros.slice(proLimit), ...stars.slice(starLimit)]
    .sort((a, b) => (pickOrder.get(a.id) || Infinity) - (pickOrder.get(b.id) || Infinity));
  const flex = overflow.slice(0, flexLimit);
  const flexIds = new Set(flex.map((member) => member.id));
  const groups = [
    { label: 'Pros', short: 'PRO', members: pros.filter((member) => !flexIds.has(member.id)), limit: proLimit },
    { label: 'Stars', short: 'STAR', members: stars.filter((member) => !flexIds.has(member.id)), limit: starLimit },
    { label: 'Bonus', short: 'BONUS', members: bonus, limit: bonusLimit },
    ...(flexLimit ? [{ label: 'Flex (Pro or Star)', short: 'FLEX', members: flex, limit: flexLimit }] : []),
  ];
  return `<div class="workspace-position-board" aria-label="Draft roster positions">${groups.map((group) => {
    const key = `${leagueId}:${group.short}`;
    const previousCount = draftPositionCounts.get(key);
    if (previousCount !== undefined && group.members.length > previousCount) draftPositionExpanded.set(key, true);
    draftPositionCounts.set(key, group.members.length);
    const expanded = draftPositionExpanded.get(key) ?? (group.members.length > 0);
    const slots = Array.from({ length: Math.max(group.limit, group.members.length) }, (_, index) => {
      const member = group.members[index];
      const retained = Boolean(member && index >= group.limit);
      return `<div class="workspace-position-slot ${member ? 'is-filled' : 'is-open'} ${retained ? 'is-retained' : ''}"><span class="workspace-position-label">${group.short} ${index + 1}${retained ? '<small>Kept</small>' : ''}</span>${member ? castTile(member, '', 'article', true) : '<span class="workspace-open-position">Open slot</span>'}</div>`;
    }).join('');
    return `<section class="workspace-position-group ${expanded ? '' : 'is-collapsed'}"><div class="workspace-position-heading"><h4>${group.label}</h4><div class="workspace-position-heading-actions"><span>${group.members.length}/${group.limit}</span><button type="button" class="workspace-position-toggle" data-position-toggle="${group.short}" aria-label="${expanded ? 'Collapse' : 'Expand'} ${group.label} slots" aria-expanded="${expanded}">⌄</button></div></div><div class="workspace-position-slots">${slots}</div></section>`;
  }).join('')}</div>`;
}

function leagueCategoryLimits(data) {
  const managers = Math.max(1, data.members.length);
  return Object.fromEntries(['Pro', 'Star'].map((role) =>
    [role, Math.floor(data.cast.filter((member) => member.role === role).length / managers)]));
}

function draftFlexAllowance(data, rosterSize) {
  const limits = leagueCategoryLimits(data);
  const managers = Math.max(1, data.members.length);
  const bonusShare = Math.floor(data.cast.filter((member) => castCategory(member) === 'Bonus').length / managers);
  return rosterSize > limits.Pro + limits.Star + bonusShare ? 1 : 0;
}

function draftableRosterSlots(data, rosterSize) {
  const limits = leagueCategoryLimits(data);
  const managers = Math.max(1, data.members.length);
  return limits.Pro + limits.Star
    + Math.floor(data.cast.filter((member) => castCategory(member) === 'Bonus').length / managers)
    + draftFlexAllowance(data, rosterSize);
}

function draftHasCapacity(data, rosterSize) {
  const managers = Math.max(1, data.members.length);
  const limits = leagueCategoryLimits(data);
  const activeCast = data.cast.filter((member) => castCategory(member) !== 'Bonus');
  const extraActive = activeCast.length - managers * (limits.Pro + limits.Star);
  const flex = draftFlexAllowance(data, rosterSize);
  return data.cast.length >= managers * rosterSize
    && draftableRosterSlots(data, rosterSize) >= rosterSize
    && (!flex || extraActive >= managers);
}

function unreservedActiveRoleCount(data, assignmentMap, role, limit) {
  const total = data.cast.filter((member) => castCategory(member) === role).length;
  const assigned = data.cast.filter((member) => castCategory(member) === role
    && assignmentMap.has(member.id)).length;
  const unfilledStandardSlots = data.members.reduce((sum, manager) => {
    const filled = data.cast.filter((member) => castCategory(member) === role
      && assignmentMap.get(member.id) === manager.fantasy_team_id).length;
    return sum + Math.max(0, limit - filled);
  }, 0);
  return total - assigned - unfilledStandardSlots;
}

function updateDraftClock(deadline, serverNow = null, paused = false) {
  const clock = $('#workspaceDraftClock');
  clearInterval(workspaceDraftTimer);
  workspaceDraftTimer = null;
  if (!clock) return;
  if (paused || !deadline) {
    clock.textContent = paused ? 'Paused' : '—';
    clock.classList.remove('urgent');
    return;
  }
  const offset = serverNow ? Date.parse(serverNow) - Date.now() : 0;
  clock.dataset.deadline = deadline;
  clock.dataset.offset = String(offset);
  const tick = () => {
    if (!clock.isConnected) return;
    const seconds = Math.max(0, Math.ceil((Date.parse(clock.dataset.deadline) - Date.now() - Number(clock.dataset.offset)) / 1000));
    clock.textContent = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
    clock.classList.toggle('urgent', seconds <= 30);
    if (seconds === 0) {
      clock.closest('.workspace-team-detail')?.querySelectorAll('[data-workspace-claim]')
        .forEach((button) => { button.disabled = true; });
    }
  };
  tick();
  workspaceDraftTimer = setInterval(tick, 1000);
}

async function loadWorkspaceData(context, { light = false, previous = null } = {}) {
  const leagueId = context.leagueId;
  const queries = {
    league: db.from('leagues').select('id,name,status,roster_size,roster_size_overridden,scoring_starts_after_week,draft_pick_deadline_at,draft_paused_at,draft_timer_disabled').eq('id', leagueId).single(),
    teams: db.from('fantasy_teams').select('id,league_id,manager_name,team_name').eq('league_id', leagueId),
    assignments: db.from('league_roster_assignments').select('cast_member_id,fantasy_team_id').eq('league_id', leagueId),
    cast: db.from('cast_members').select('*').order('name'),
    members: db.rpc('list_league_members', { p_league_id: leagueId }),
    readiness: db.rpc('get_league_draft_readiness', { p_league_id: leagueId }),
    roles: db.from('roles').select('id,name,appearance_points'),
    rates: db.from('league_role_rates').select('role_id,appearance_points').eq('league_id', leagueId),
    weeks: db.from('weeks').select('*').order('number'),
    pairs: db.from('partnerships').select('id,star_id,pro_id,active,partnership_name'),
    dances: db.from('dances').select('id,week_id,kind,partnership_id,name,dance_type,song,sort_order').order('sort_order'),
    scores: db.from('dance_judge_scores').select('dance_id,judge_name,score'),
    appearances: db.from('dance_appearances').select('dance_id,cast_member_id'),
    snapshots: db.from('league_weekly_roster_snapshots').select('*').eq('league_id', leagueId),
    order: db.from('league_draft_order').select('draft_position,fantasy_team_id').eq('league_id', leagueId).order('draft_position'),
    picks: db.from('league_draft_picks').select('pick_number,round_number,fantasy_team_id,cast_member_id,picked_at,is_auto_pick').eq('league_id', leagueId).order('pick_number'),
  };
  const full = !light || !previous || previous.context.leagueId !== leagueId
    || Date.now() - lastFullWorkspaceLoadAt >= fullWorkspaceRefreshMs;
  const selected = Object.entries(queries).filter(([key]) => full || fastWorkspaceKeys.has(key));
  const results = await Promise.all(selected.map(([, query]) => query));
  const failure = results.find((result) => result.error)?.error;
  if (failure) throw failure;
  if (full) lastFullWorkspaceLoadAt = Date.now();
  return { ...(full ? {} : previous.data),
    ...Object.fromEntries(selected.map(([key], index) => [key, results[index].data || []])) };
}

function renderStandings(context, data, score, assignmentMap, memberByTeam, refresh) {
  const rows = [...data.teams].map((team) => ({ ...team, points: score.totalByTeam.get(team.id) || 0,
    manager: memberByTeam.get(team.id)?.display_name || team.manager_name })).sort((a, b) => b.points - a.points || (a.team_name || a.manager).localeCompare(b.team_name || b.manager));
  const isSetup = context.leagueStatus === 'setup';
  const isDrafting = context.leagueStatus === 'drafting';
  $('#memberOverview h1').textContent = isSetup || isDrafting ? 'Draft Home' : 'Home';
  $('#standings').classList.toggle('is-draft-home', isSetup || isDrafting);
  $('#standingsLeagueName').textContent = context.leagueName;
  $('#standingsSubtitle').textContent = isSetup
    ? 'Your league is getting ready for its draft.'
    : context.leagueStatus === 'drafting' ? 'The draft is underway. Standings begin after every roster is filled.'
      : score.scoringWeeks.length ? `Through ${score.scoringWeeks.at(-1).title || (score.scoringWeeks.at(-1).theme ? `${score.scoringWeeks.at(-1).theme} Week` : `Week ${score.scoringWeeks.at(-1).number}`)} · current fantasy-team totals` : 'The season is ready. Scores will appear after the first completed show.';
  const turn = draftTurn(data.order, data.picks, context.rosterSize);
  const regularMembers = data.members.filter((member) => member.member_role === 'member');
  const readyIds = new Set(data.readiness.filter((item) => item.ready_at).map((item) => item.user_id));
  const readyCount = regularMembers.filter((member) => readyIds.has(member.user_id)).length;
  const setupPanel = isSetup ? `<section class="card pad workspace-setup-panel"><p class="eyebrow">Before the draft</p><h2>Build your league</h2><p class="sub">${data.members.length} of 3–5 managers joined. ${data.members.length < 3 ? `Invite ${3 - data.members.length} more to start.` : `${readyCount} of ${regularMembers.length} regular managers ready.`} The preset roster has ${context.rosterSize} picks per team and adjusts as managers join.</p><div class="workspace-setup-facts"><span><b>${data.members.length}</b> managers</span><span><b>${context.rosterSize}</b> draft rounds</span><span><b>${data.cast.length}</b> cast in pool</span></div>${context.leagueRole === 'owner' ? `<div class="modal-actions">${data.members.length < 5 ? '<button id="overviewInvitePlayers">Invite players</button>' : ''}<button id="overviewLeagueSettings" class="secondary">League settings</button></div>` : '<p class="sub">Open Draft to mark yourself ready. The commissioner can start once every regular manager is ready.</p>'}</section>` : isDrafting ? `<section class="card pad workspace-setup-panel"><p class="eyebrow">${context.draftPaused ? 'Draft paused' : 'Draft in progress'}</p><h2>Round ${turn?.round || context.rosterSize} of ${context.rosterSize}</h2><p class="sub">${data.picks.length} of ${data.order.length * context.rosterSize} picks complete. ${context.draftTimerDisabled ? 'This draft has no timer or automatic picks.' : context.draftAiringLocked ? 'The clock and picks resume when this week is marked complete.' : context.draftPaused ? 'The clock and picks are paused until the league owner resumes.' : turn ? `${safe(memberByTeam.get(turn.teamId)?.display_name || 'The next manager')} is on the clock.` : 'Every roster is filled.'}</p><a class="workspace-inline-link" href="#teams" id="overviewOpenDraft">View the draft</a></section>` : !score.scoringWeeks.length ? '<section class="card pad workspace-setup-panel"><p class="eyebrow">Season ready</p><h2>Waiting for the first completed show</h2><p class="sub">Your draft teams are set. Weekly points and highlights will appear after a show is completed.</p></section>' : '';
  const scored = context.leagueStatus === 'active' && score.scoringWeeks.length > 0;
  const latestWeek = score.scoringWeeks.at(-1);
  const nextWeek = context.leagueStatus === 'active' ? data.weeks.find((week) => !week.is_complete && (!latestWeek || week.number > latestWeek.number)) : null;
  const focusWeek = nextWeek || latestWeek;
  const focusDances = data.dances.filter((dance) => dance.week_id === focusWeek?.id && dance.kind === 'competitive');
  const scoredDances = new Set(data.scores.map((item) => item.dance_id));
  const featuredPair = data.pairs.find((pair) => pair.id === focusDances[0]?.partnership_id);
  const featuredCast = data.cast.find((cast) => cast.id === featuredPair?.star_id);
  let episodeContainer = $('#episodeSpotlight');
  if (!episodeContainer) {
    episodeContainer = document.createElement('div');
    episodeContainer.id = 'episodeSpotlight';
    $('#memberOverview .standings-head').after(episodeContainer);
  }
  episodeContainer.innerHTML = focusWeek ? episodeSpotlight({ week: focusWeek,
    state: nextWeek ? focusDances.some((dance) => scoredDances.has(dance.id)) ? 'receiving' : 'upcoming' : 'complete',
    date: focusWeek.air_date ? new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${focusWeek.air_date}T00:00:00Z`)) : '',
    scored: focusDances.filter((dance) => scoredDances.has(dance.id)).length, performances: focusDances.length,
    teamPoints: !nextWeek && context.fantasyTeamId ? score.pointsByWeekTeam.get(`${focusWeek.id}:${context.fantasyTeamId}`) || 0 : null,
    portrait: featuredCast ? castImage(featuredCast) : '' }) : '';
  episodeContainer.querySelector('[data-open-episode]')?.addEventListener('click', () => {
    selectedDanceWeekId = focusWeek.id;
    document.querySelector('nav [data-view="score"]')?.click();
  });
  let controls = $('#standingsMode');
  if (!controls) {
    controls = document.createElement('div');
    controls.id = 'standingsMode';
    $('#memberOverview .overview-layout').before(controls);
  }
  controls.hidden = !scored;
  controls.innerHTML = scored ? standingsSwitch(workspaceStandingsMode, latestWeek) : '';
  const changePeriod = (event) => {
    const button = event.target.closest('[data-standings-mode]');
    if (!button) return;
    if (workspaceStandingsMode === button.dataset.standingsMode) return;
    workspaceStandingsMode = button.dataset.standingsMode;
    renderStandings(context, data, score, assignmentMap, memberByTeam, refresh);
  };
  controls.onpointerdown = changePeriod;
  controls.onclick = changePeriod;
  const periodPoints = (team) => workspaceStandingsMode === 'week' ? score.pointsByWeekTeam.get(`${latestWeek.id}:${team.id}`) || 0 : team.points;
  const displayRows = scored ? [...rows].sort((a, b) => periodPoints(b) - periodPoints(a) || a.manager.localeCompare(b.manager)) : rows;
  const previousPoints = (team) => team.points - (score.pointsByWeekTeam.get(`${latestWeek.id}:${team.id}`) || 0);
  const previousRows = scored ? [...rows].sort((a, b) => previousPoints(b) - previousPoints(a)) : [];
  const castPoints = (team) => data.cast.map((cast) => ({ cast, points: workspaceStandingsMode === 'week'
    ? score.snapshotByKey.get(`${latestWeek.id}:${cast.id}`)?.fantasy_team_id === team.id
      ? (score.pointsByWeekCast.get(`${latestWeek.id}:${cast.id}`)?.official || 0) + (score.pointsByWeekCast.get(`${latestWeek.id}:${cast.id}`)?.appearances || 0) : 0
    : score.pointsByTeamCast.get(team.id)?.get(cast.id) || 0 }))
    .filter(({ cast, points }) => points || workspaceStandingsMode === 'season' && assignmentMap.get(cast.id) === team.id)
    .sort((a, b) => b.points - a.points || a.cast.name.localeCompare(b.cast.name));
  if (scored && !rows.some((team) => team.id === selectedWorkspaceOverviewTeamId)) selectedWorkspaceOverviewTeamId = rows[0]?.id;
  $('#standingsContent').innerHTML = scored ? `<div class="standings-grid">${displayRows.map((team, index) => {
    const leaders = castPoints(team);
    const total = periodPoints(team);
    const tied = displayRows.filter((item) => periodPoints(item) === periodPoints(displayRows[0])).length > 1 && total === periodPoints(displayRows[0]);
    const rank = displayRows.findIndex((item) => periodPoints(item) === total) + 1;
    const movement = score.scoringWeeks.length > 1
      ? previousRows.findIndex((item) => previousPoints(item) === previousPoints(team)) - rows.findIndex((item) => item.points === team.points)
      : null;
    return standingCard({ id: team.id, rank, manager: team.manager,
      name: team.team_name || `${team.manager.split(' ')[0]}'s Team`,
      contributors: leaders.map(({ cast, points }) => ({ name: cast.name, points })), total,
      weekPoints: score.pointsByWeekTeam.get(`${latestWeek.id}:${team.id}`) || 0, movement, period: workspaceStandingsMode,
      selected: team.id === selectedWorkspaceOverviewTeamId, leader: index === 0, tied });
  }).join('')}</div>` : `${setupPanel}${rows.length ? `<div class="workspace-standings-list">${rows.map((team) => `<button type="button" class="card workspace-standing-card" data-workspace-standing="${team.id}" aria-label="View ${safe(team.team_name || team.manager)} roster"><span class="workspace-rank">${isSetup ? '•' : `${[...assignmentMap.values()].filter((id) => id === team.id).length}`}</span><span><small>${safe(team.manager)}</small><b>${safe(team.team_name || `${team.manager.split(' ')[0]}'s Team`)}</b></span><strong>${isSetup ? data.members.find((member) => member.fantasy_team_id === team.id)?.member_role === 'owner' ? 'Commissioner' : readyIds.has(data.members.find((member) => member.fantasy_team_id === team.id)?.user_id) ? 'Ready' : 'Not ready' : `${[...assignmentMap.values()].filter((id) => id === team.id).length}/${context.rosterSize} cast`}</strong></button>`).join('')}</div>` : '<div class="card pad">No teams yet.</div>'}`;
  $('#overviewInvitePlayers')?.addEventListener('click', () => openInviteManager(context, refresh));
  $('#overviewLeagueSettings')?.addEventListener('click', () => openLeagueSettings(context, refresh));
  $('#overviewOpenDraft')?.addEventListener('click', (event) => { event.preventDefault(); $('#myTeamNav').click(); });
  const detailMarkup = (team) => {
    const leaders = castPoints(team).slice(0, 5);
    const castRows = leaders.map(({ cast, points }) => {
      const parts = (workspaceStandingsMode === 'week' ? [latestWeek] : score.scoringWeeks).reduce((total, week) => {
        if (score.snapshotByKey.get(`${week.id}:${cast.id}`)?.fantasy_team_id === team.id) {
          const entry = score.pointsByWeekCast.get(`${week.id}:${cast.id}`);
          total.official += entry?.official || 0; total.appearances += entry?.appearances || 0;
        }
        return total;
      }, { official: 0, appearances: 0 });
      const role = cast.role;
      const appearanceRate = cast.is_hough ? score.rateByName.get('Hough') || 0
        : role === 'Surprise' ? Number(cast.custom_appearance_points) || 0 : score.rateByName.get(role) || 0;
      return { member: cast, role, appearanceRate, displayRole: role === 'DWTS Next Pro' ? 'Next Pro' : role,
        official: parts.official, appearances: parts.appearances, total: points };
    });
    return overviewTeamDetail({ name: team.team_name || `${team.manager.split(' ')[0]}'s Team`,
      manager: team.manager, total: periodPoints(team), castRows, period: workspaceStandingsMode });
  };
  const bindCastDetail = (container, team) => container.querySelectorAll('[data-score-cast-detail]').forEach((item) => {
    const open = () => openWorkspaceCastProfile(data.cast.find((cast) => cast.id === item.dataset.scoreCastDetail), team.team_name);
    item.addEventListener('click', open);
    item.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
  const drawDetail = () => {
    const panel = $('#overviewTeamDetail');
    const team = rows.find((item) => item.id === selectedWorkspaceOverviewTeamId);
    if (!scored || !team || !$('#standings').classList.contains('active') || $('.overview-layout').getBoundingClientRect().width < 1030) { panel.innerHTML = ''; return; }
    panel.innerHTML = `<section class="card overview-team-detail">${detailMarkup(team)}</section>`;
    bindCastDetail(panel, team);
  };
  $('#standingsContent').querySelectorAll('[data-standing-team], [data-workspace-standing]').forEach((button) => {
    const open = () => {
    const team = rows.find((item) => item.id === (button.dataset.standingTeam || button.dataset.workspaceStanding));
    if (scored) {
      selectedWorkspaceOverviewTeamId = team.id;
      $('#standingsContent').querySelectorAll('[data-standing-team]').forEach((item) => item.classList.toggle('selected', item === button));
      if ($('.overview-layout').getBoundingClientRect().width >= 1030) drawDetail();
      else { dialog(`<div class="overview-mobile-detail">${detailMarkup(team)}</div>`); bindCastDetail($('#modalBody'), team); }
      return;
    }
    const roster = data.cast.filter((cast) => assignmentMap.get(cast.id) === team.id)
      .sort((a, b) => (score.pointsByTeamCast.get(team.id)?.get(b.id) || 0)
        - (score.pointsByTeamCast.get(team.id)?.get(a.id) || 0));
    dialog(`<p class="eyebrow">${safe(context.leagueName)}</p><h2>${safe(team.team_name || `${team.manager.split(' ')[0]}'s Team`)}</h2><p class="sub">Managed by ${safe(team.manager)} · ${context.leagueStatus === 'active' ? `${team.points} season points` : `${roster.length}/${context.rosterSize} cast drafted`}</p><div class="workspace-cast-list">${roster.map((cast) => castTile(cast, context.leagueStatus === 'active' ? `<strong class="workspace-points">${score.pointsByTeamCast.get(team.id)?.get(cast.id) || 0} pts</strong>` : '')).join('') || '<p class="sub">The draft has not filled this roster yet.</p>'}</div>`);
    };
    button.addEventListener('click', open);
    button.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
  drawDetail();
  window.removeEventListener('resize', window.workspaceOverviewResize);
  window.workspaceOverviewResize = drawDetail;
  window.addEventListener('resize', drawDetail);
  $('.highlight-preview').hidden = !scored;
  $('.highlight-preview').style.display = scored ? '' : 'none';
  if (scored) renderWorkspaceHighlights(data, score, rows);
}

function renderWorkspaceHighlights(data, score, rows) {
  const week = score.scoringWeeks.at(-1);
  if (!week) return;
  const teamScores = rows.map((team) => ({ team, points: score.pointsByWeekTeam.get(`${week.id}:${team.id}`) || 0 }));
  const bestTeam = Math.max(0, ...teamScores.map((item) => item.points));
  const castScores = data.cast.map((cast) => {
    const entry = score.pointsByWeekCast.get(`${week.id}:${cast.id}`);
    return { cast, points: (entry?.official || 0) + (entry?.appearances || 0), appearances: data.appearances.filter((appearance) =>
      appearance.cast_member_id === cast.id && data.dances.some((dance) => dance.id === appearance.dance_id && dance.week_id === week.id)).length };
  });
  const bestCast = Math.max(0, ...castScores.map((item) => item.points));
  const mostAppearances = Math.max(0, ...castScores.map((item) => item.appearances));
  const winners = bestTeam ? teamScores.filter((item) => item.points === bestTeam) : [];
  const mvps = bestCast ? castScores.filter((item) => item.points === bestCast) : [];
  const leaders = mostAppearances ? castScores.filter((item) => item.appearances === mostAppearances) : [];
  $('#highlightWeek').textContent = week.title || (week.theme ? `${week.theme} Week` : `Week ${week.number}`);
  $('#leagueHighlightCards').innerHTML = highlightCards({ teamScore: bestTeam,
    teamNames: winners.map(({ team }) => team.team_name || team.manager), castScore: bestCast,
    castNames: mvps.map(({ cast }) => cast.name), appearances: mostAppearances,
    appearanceNames: leaders.map(({ cast }) => cast.name) });
}

function renderMyTeam(context, data, score, assignmentMap, memberByTeam, refresh) {
  const enforceRoleBalance = context.leagueId !== defaultLeagueId;
  const ownTeam = data.teams.find((team) => team.id === context.fantasyTeamId);
  const body = $('#publicTeamResults');
  if (!ownTeam) { body.innerHTML = '<div class="card pad">Your team has not been connected yet.</div>'; return; }
  const roster = data.cast.filter((member) => assignmentMap.get(member.id) === ownTeam.id);
  const available = data.cast.filter((member) => !assignmentMap.has(member.id));
  const latestCompleted = [...data.weeks].reverse().find((week) => week.is_complete);
  const visibleWeeks = context.leagueStatus === 'active' ? data.weeks.filter((week) =>
    week.number <= (latestCompleted?.number ?? data.weeks[0]?.number ?? 0) + (latestCompleted ? 1 : 0)) : [];
  if (selectedTeamWeekId !== 'all' && !visibleWeeks.some((week) => week.id === selectedTeamWeekId)) selectedTeamWeekId = 'all';
  const selectedWeek = visibleWeeks.find((week) => week.id === selectedTeamWeekId);
  const historicalIds = new Set(data.snapshots.filter((snapshot) =>
    snapshot.fantasy_team_id === ownTeam.id && score.scoringWeeks.some((week) => week.id === snapshot.week_id))
    .map((snapshot) => snapshot.cast_member_id));
  const displayRoster = context.leagueStatus !== 'active' ? roster
    : selectedWeek?.is_complete ? data.cast.filter((member) =>
      score.snapshotByKey.get(`${selectedWeek.id}:${member.id}`)?.fantasy_team_id === ownTeam.id)
      : selectedWeek ? roster : data.cast.filter((member) =>
        assignmentMap.get(member.id) === ownTeam.id || historicalIds.has(member.id));
  const scoreForCast = (member) => {
    const weeks = selectedWeek ? selectedWeek.is_complete ? [selectedWeek] : [] : score.scoringWeeks;
    return weeks.reduce((parts, week) => {
      if (score.snapshotByKey.get(`${week.id}:${member.id}`)?.fantasy_team_id !== ownTeam.id) return parts;
      const entry = score.pointsByWeekCast.get(`${week.id}:${member.id}`);
      parts.official += entry?.official || 0;
      parts.appearances += entry?.appearances || 0;
      return parts;
    }, { official: 0, appearances: 0 });
  };
  if (context.leagueStatus === 'active') displayRoster.sort((a, b) => {
    const aPoints = scoreForCast(a);
    const bPoints = scoreForCast(b);
    return (bPoints.official + bPoints.appearances) - (aPoints.official + aPoints.appearances)
      || a.name.localeCompare(b.name);
  });
  const turn = draftTurn(data.order, data.picks, context.rosterSize);
  const isYourTurn = context.leagueStatus === 'drafting' && !context.draftPaused && turn?.teamId === ownTeam.id;
  const currentRound = turn?.round || context.rosterSize;
  if (!selectedDraftRound || selectedDraftRound > context.rosterSize) selectedDraftRound = currentRound;
  const draftRound = selectedDraftRound;
  const roundSlots = data.order.length ? data.order.map((slot, index) => {
    const roundPosition = draftRound % 2 ? index : data.order.length - index - 1;
    const teamSlot = data.order[roundPosition];
    const pickNumber = (draftRound - 1) * data.order.length + index + 1;
    const pick = data.picks.find((item) => item.pick_number === pickNumber);
    const cast = pick && data.cast.find((member) => member.id === pick.cast_member_id);
    return `<div class="workspace-round-pick ${turn?.pickNumber === pickNumber ? 'on-clock' : ''}"><span>#${pickNumber}</span><div><b>${safe(memberByTeam.get(teamSlot.fantasy_team_id)?.display_name || 'Manager')}</b><small>${cast ? `${safe(cast.name)}${pick.is_auto_pick ? ' · Auto pick' : ''}` : turn?.pickNumber === pickNumber ? context.draftPaused ? 'Paused' : 'On the clock' : 'Waiting to pick'}</small></div></div>`;
  }).join('') : '';
  $('#myTeamTitle').textContent = context.leagueStatus === 'active' ? ownTeam.team_name || 'My Team' : 'Draft';
  $('#myTeamEyebrow').textContent = context.leagueStatus === 'active'
    ? `${(context.displayName || 'Your').split(' ')[0]}'s Manager View`
    : `${context.displayName || 'Your'} · ${context.leagueName}`;
  $('#myTeamSubtitle').textContent = context.leagueStatus === 'setup'
    ? 'Get ready with your league. The commissioner can start when 3–5 managers have joined and every regular manager is ready.'
    : context.leagueStatus === 'drafting' ? 'Follow the draft order and claim cast members when it is your turn.'
      : 'View your roster, weekly scores, and the available cast.';
  const weekHistory = visibleWeeks.map((week) => {
    const date = week.air_date && !week.is_complete
      ? new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })
        .format(new Date(`${week.air_date}T00:00:00Z`)) : '';
    const value = week.is_complete ? score.pointsByWeekTeam.get(`${week.id}:${ownTeam.id}`) || 0 : date || 'TBA';
    return `<button type="button" class="${selectedTeamWeekId === week.id ? 'selected' : ''}" data-team-week="${week.id}" aria-pressed="${selectedTeamWeekId === week.id}"><span>Week ${week.number}</span><strong class="${week.is_complete ? '' : 'air-date'}">${safe(value)}</strong></button>`;
  }).join('');
  const selectedTotal = selectedWeek
    ? selectedWeek.is_complete ? score.pointsByWeekTeam.get(`${selectedWeek.id}:${ownTeam.id}`) || 0 : 0
    : score.totalByTeam.get(ownTeam.id) || 0;
  const seasonSummary = `<div class="team-summary-strip"><div class="team-history-strip">${weekHistory || '<p class="sub">Weekly history will appear after scoring begins.</p>'}</div><div class="league-detail-total"><strong>${selectedTotal}</strong><span>${selectedWeek ? 'week' : 'season'} points</span></div></div>`;
  const rosterScoreRows = displayRoster.map((member) => {
    const parts = scoreForCast(member);
    const snapshot = selectedWeek?.is_complete ? score.snapshotByKey.get(`${selectedWeek.id}:${member.id}`) : null;
    const role = snapshot?.cast_role || member.role;
    const rate = snapshot?.appearance_points ?? (member.is_hough ? score.rateByName.get('Hough')
      : role === 'Surprise' ? member.custom_appearance_points : score.rateByName.get(role)) ?? 0;
    return { member, role, appearanceRate: Number(rate) || 0,
      displayRole: role === 'DWTS Next Pro' ? 'Next Pro' : role,
      official: parts.official, appearances: parts.appearances, total: parts.official + parts.appearances };
  });
  const regularMembers = data.members.filter((member) => member.member_role === 'member');
  const readyIds = new Set(data.readiness.filter((item) => item.ready_at).map((item) => item.user_id));
  const readyCount = regularMembers.filter((member) => readyIds.has(member.user_id)).length;
  const enoughEligibleCast = !enforceRoleBalance || draftHasCapacity(data, context.rosterSize);
  const canStartDraft = data.members.length >= 3 && data.members.length <= 5
    && readyCount === regularMembers.length && enoughEligibleCast && !context.draftAiringLocked;
  const ownReady = readyIds.has(context.userId);
  const readinessRows = data.members.map((member) => {
    const isOwner = member.member_role === 'owner';
    const isReady = readyIds.has(member.user_id);
    return `<li class="workspace-ready-person"><span class="workspace-ready-avatar">${member.avatar_url ? `<img src="${safe(member.avatar_url)}" alt="">` : safe((member.display_name || member.username || 'M').charAt(0).toUpperCase())}</span><span class="workspace-ready-name"><b>${safe(member.display_name || member.username || 'Manager')}</b><small>${isOwner ? 'Commissioner' : `@${safe(member.username || 'manager')}`}</small></span><span class="workspace-ready-state ${isOwner ? 'is-owner' : isReady ? 'is-ready' : 'is-waiting'}">${isOwner ? 'Commissioner' : isReady ? 'Ready' : 'Not ready'}</span></li>`;
  }).join('');
  const categoryLimits = leagueCategoryLimits(data);
  const teamCategoryCount = (role) => roster.filter((member) => castCategory(member) === role).length;
  const draftFlex = draftFlexAllowance(data, context.rosterSize);
  const draftBonusLimit = Math.max(0, context.rosterSize - categoryLimits.Pro - categoryLimits.Star - draftFlex);
  const activeCount = teamCategoryCount('Pro') + teamCategoryCount('Star');
  const draftCategoryUnavailable = (member) => {
    if (context.leagueStatus !== 'drafting') return '';
    if (!enforceRoleBalance) return '';
    const category = castCategory(member);
    if (category === 'Bonus') return teamCategoryCount('Bonus') >= draftBonusLimit ? 'Limit reached' : '';
    if (teamCategoryCount(category) >= categoryLimits[category] + draftFlex
        || activeCount >= categoryLimits.Pro + categoryLimits.Star + draftFlex) return 'Limit reached';
    return teamCategoryCount(category) >= categoryLimits[category]
      && unreservedActiveRoleCount(data, assignmentMap, category, categoryLimits[category]) <= 0
      ? 'Reserved' : '';
  };
  const airingLock = context.leagueStatus === 'active' && isTradeAiringLocked(data.weeks);
  const rosterRule = enforceRoleBalance ? `<p class="workspace-category-rule"><b>Roster balance</b> ${teamCategoryCount('Pro')}/${categoryLimits.Pro} active pros · ${teamCategoryCount('Star')}/${categoryLimits.Star} active stars · ${teamCategoryCount('Bonus')}${context.leagueStatus === 'drafting' ? `/${draftBonusLimit}` : ''} bonus.${draftFlex && context.leagueStatus !== 'active' ? ' One extra Pro or Star pick is available to make this preset draftable.' : ''} Eliminated cast and other roles count as bonus. Existing players stay when limits drop; a new active Pro or Star can join only if the resulting roster is within the current limit.</p>` : '';
  const draftStrip = context.leagueStatus === 'setup'
    ? `<div class="workspace-draft-setup"><div class="workspace-draft-strip"><div><small>Draft setup</small><strong>${regularMembers.length ? `${readyCount} of ${regularMembers.length} members ready` : 'Waiting for managers'}</strong><p class="sub">${data.members.length} managers · ${context.rosterSize} rounds · preset roster size</p></div>${context.leagueRole === 'owner' ? `<button id="startDraftFromTeam" ${canStartDraft ? '' : 'disabled'}>Start draft</button>` : `<button id="toggleDraftReady" type="button" class="${ownReady ? 'secondary' : ''}">${ownReady ? 'Unready' : 'Ready'}</button>`}</div><div class="workspace-ready-board"><div class="workspace-ready-heading"><h3>Managers</h3><span>${regularMembers.length ? `${readyCount}/${regularMembers.length} ready` : 'No members yet'}</span></div><ul class="workspace-ready-list">${readinessRows}</ul>${context.leagueRole === 'owner' && !canStartDraft ? `<p class="workspace-ready-note">${data.members.length < 3 ? `Invite ${3 - data.members.length} more ${3 - data.members.length === 1 ? 'manager' : 'managers'} to start.` : data.members.length > 5 ? 'Leagues can now draft with 3–5 managers. Remove one manager to continue.' : !enoughEligibleCast ? 'The current cast pool cannot fill every roster under the Pro, Star, and Bonus limits.' : context.draftAiringLocked ? 'Drafting resumes when this week is marked complete.' : 'Waiting for every regular manager to be ready.'}</p>` : ''}</div></div>`
    : context.leagueStatus === 'drafting'
      ? `<div class="workspace-draft-strip workspace-draft-status"><div><small>Round ${currentRound} of ${context.rosterSize} · Pick ${turn?.pickNumber || '—'}</small><strong>${context.draftAiringLocked ? 'Draft on hold for the show' : context.draftPaused ? 'Draft paused' : isYourTurn ? 'You are on the clock' : `${safe(memberByTeam.get(turn?.teamId)?.display_name || 'Next manager')} is on the clock`}</strong><p class="sub">${context.draftAiringLocked ? 'Picks and the clock resume when this week is marked complete.' : context.draftTimerDisabled ? 'No time limit or automatic picks. Each manager picks when it is their turn.' : context.draftPaused ? 'The league owner paused the draft. No picks or automatic selections can happen until it resumes.' : 'Each manager has two minutes to pick before the draft selects a random available cast member.'}</p>${context.leagueRole === 'owner' && !context.draftTimerDisabled && !context.draftAiringLocked ? `<button type="button" id="toggleDraftPause" class="secondary">${context.draftPaused ? 'Resume draft' : 'Pause draft'}</button>` : ''}</div>${context.draftTimerDisabled ? '' : `<div class="workspace-draft-timer"><small>${context.draftPaused ? 'Draft clock' : 'Time left'}</small><strong id="workspaceDraftClock" aria-live="off">${context.draftPaused ? 'Paused' : '02:00'}</strong></div>`}</div>`
      : seasonSummary;
  const canClaim = isYourTurn || context.leagueStatus === 'active' && !airingLock;
  const castScrollTop = body.querySelector('.workspace-available-list')?.scrollTop || 0;
  const drafting = context.leagueStatus === 'drafting';
  const positionBoard = drafting ? draftPositionBoard(roster, data.picks, categoryLimits.Pro,
    categoryLimits.Star, draftBonusLimit, draftFlex, context.leagueId) : '';
  const rosterContent = drafting ? positionBoard
    : `${rosterRule}<div class="workspace-cast-list">${roster.map((member) => castTile(member, '', 'article', true)).join('') || '<p class="sub">Your picks will appear here.</p>'}</div>`;
  const filteredAvailable = drafting && draftPoolFilter !== 'All'
    ? available.filter((member) => castCategory(member) === draftPoolFilter) : available;
  const poolFilters = drafting ? `<div class="workspace-pool-filters" role="group" aria-label="Filter available cast by role">${[
    ['All', 'All'], ['Pro', 'Pros'], ['Star', 'Stars'], ['Bonus', 'Bonus'],
  ].map(([category, label]) => `<button type="button" data-draft-pool-filter="${category}" class="${draftPoolFilter === category ? 'selected' : ''}" aria-pressed="${draftPoolFilter === category}">${label} <span>${category === 'All' ? available.length : available.filter((member) => castCategory(member) === category).length}</span></button>`).join('')}</div>` : '';
  const availableTiles = filteredAvailable.map((member) => {
    const unavailable = draftCategoryUnavailable(member);
    return castTile(member, canClaim ? `<button data-workspace-claim="${member.id}" ${unavailable ? `disabled title="${unavailable === 'Reserved' ? 'Reserved for another manager’s standard role slot' : 'Category limit reached'}"` : ''}>${unavailable || 'Claim'}</button>` : '', 'article', true);
  }).join('') || '<p class="sub">No cast members in this category are available.</p>';
  if (context.leagueStatus !== 'setup') {
    body.innerHTML = `<section class="card public-team-detail workspace-team-detail">${draftStrip}${drafting ? `<section class="workspace-draft-rounds"><div class="public-section-head"><div><p class="eyebrow">Draft board</p><h3>Round ${draftRound} picks</h3></div><span>${data.picks.length} of ${data.order.length * context.rosterSize} picked</span></div><div class="workspace-round-tabs" role="group" aria-label="Draft rounds">${Array.from({ length: context.rosterSize }, (_, index) => `<button type="button" data-draft-round="${index + 1}" class="${draftRound === index + 1 ? 'selected' : ''}" aria-pressed="${draftRound === index + 1}">Round ${index + 1}</button>`).join('')}</div><div class="workspace-round-picks">${roundSlots}</div></section>` : ''}<div class="public-team-columns"><section><div class="public-section-head"><div><p class="eyebrow">Roster</p><h3>Team Roster · ${roster.length}/${context.rosterSize}</h3></div></div>${rosterContent}</section><div class="team-side-column"><section class="available-cast-panel"><div class="public-section-head"><div><p class="eyebrow">${drafting ? 'Draft pool' : 'Free agents'}</p><h3>Available Cast</h3></div><span>${drafting && draftPoolFilter !== 'All' ? `${filteredAvailable.length} of ${available.length}` : available.length} available</span></div><p class="sub">${airingLock ? 'Roster changes pause from two hours before the show until two hours after.' : isYourTurn ? 'It is your turn. Claim one cast member below.' : context.draftAiringLocked ? 'Draft picks resume when this week is marked complete.' : context.draftPaused ? 'The draft is paused. Claims reopen when the owner resumes.' : drafting ? 'Claims open when it is your turn.' : context.leagueStatus === 'active' ? 'Claim a cast member by releasing one from your roster.' : 'Claims open after the draft starts.'}</p>${poolFilters}<div class="workspace-available-list">${availableTiles}</div></section>${context.leagueStatus === 'active' ? '<section id="workspaceTradeCenter" class="card pad workspace-trades">Loading trades…</section>' : ''}</div></div></section>`;
  }
  if (context.leagueStatus === 'setup') {
    body.innerHTML = `<section class="card public-team-detail workspace-team-detail is-setup"><div class="workspace-setup-intro"><p class="eyebrow">Before the draft</p><h2>Get ready to draft</h2><p class="sub">${context.leagueRole === 'owner' ? 'Invite managers and check their readiness. You can start once at least three managers have joined and every member is ready.' : 'Mark yourself ready when you can join the draft. You can change your status until the commissioner starts.'}</p></div>${draftStrip}<div class="workspace-setup-footer"><div><p class="eyebrow">Your team</p><h3>${safe(ownTeam.team_name || 'My Team')}</h3><p class="sub">${context.rosterSize} picks will fill your roster once the draft begins.</p></div><button type="button" class="secondary workspace-roster-edit">Edit team name</button></div></section>`;
  }
  if (context.leagueStatus === 'active') {
    const availableMarkup = available.map((member) => `<article class="league-cast-person available-cast-person"><button type="button" class="available-profile-button" data-workspace-available-cast="${member.id}" aria-label="View ${safe(member.name)} profile"><img src="${safe(castImage(member))}" style="object-position:${Number(member.image_position) || 50}% center" alt=""><span><strong>${safe(member.name)}</strong><small>${safe(member.role === 'DWTS Next Pro' ? 'Next Pro' : member.role)}</small></span></button><button type="button" class="claim-cast-button" data-workspace-claim="${member.id}" ${airingLock ? 'disabled title="Roster changes pause around the airing"' : ''}>${airingLock ? 'Locked' : 'Claim'}</button></article>`).join('');
    body.innerHTML = teamPage({ weekHistory, total: selectedTotal, period: selectedWeek ? 'week' : 'season',
      rosterRows: `${airingLock ? '<p class="sub workspace-roster-note">Roster changes pause from two hours before the show until two hours after.</p>' : ''}${rosterRule}${selectedWeek?.is_complete ? `<p class="sub workspace-roster-note">Week ${selectedWeek.number} uses the roster saved on its airing date.</p>` : ''}${scoreRows(rosterScoreRows, { withImages: true, imageFor: castImage, historicalJudges: !selectedWeek })}`,
      available: available.length, availableMarkup,
      tradesMarkup: '<section id="workspaceTradeCenter" class="trade-center card"><div class="trade-center-loading">Loading trades…</div></section>' });
    const scoringSection = body.querySelector('.public-team-columns > section:first-child');
    scoringSection.querySelector('h3').textContent = selectedWeek ? `Week ${selectedWeek.number} Roster` : 'Team Roster';
    scoringSection.querySelectorAll('[data-score-cast-detail]').forEach((row) => {
      const open = () => {
        const cast = data.cast.find((member) => member.id === row.dataset.scoreCastDetail);
        if (cast) openWorkspaceCastProfile(cast, selectedWeek?.is_complete
          ? score.snapshotByKey.get(`${selectedWeek.id}:${cast.id}`)?.team_name || ownTeam.team_name
          : ownTeam.team_name);
      };
      row.addEventListener('click', open);
      row.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); }
      });
    });
    body.querySelectorAll('[data-team-week]').forEach((button) => button.addEventListener('click', () => {
      selectedTeamWeekId = selectedTeamWeekId === button.dataset.teamWeek ? 'all' : button.dataset.teamWeek;
      renderMyTeam(context, data, score, assignmentMap, memberByTeam, refresh);
    }));
    body.querySelectorAll('[data-workspace-available-cast]').forEach((button) => button.addEventListener('click', () => {
      const cast = data.cast.find((member) => member.id === button.dataset.workspaceAvailableCast);
      if (cast) openWorkspaceCastProfile(cast);
    }));
  }
  body.firstElementChild.classList.toggle('is-drafting', context.leagueStatus === 'drafting');
  body.querySelectorAll('[data-workspace-profile]').forEach((button) => button.addEventListener('click', () => {
    const cast = data.cast.find((member) => member.id === button.dataset.workspaceProfile);
    if (cast) openWorkspaceCastProfile(cast, memberByTeam.get(assignmentMap.get(cast.id))?.team_name || 'Available cast');
  }));
  if (body.querySelector('.workspace-available-list')) body.querySelector('.workspace-available-list').scrollTop = castScrollTop;
  if (context.leagueStatus === 'drafting') {
    const rosterHeading = body.querySelector('.public-team-columns > section:first-child .public-section-head');
    rosterHeading.querySelector('h3').textContent = `${ownTeam.team_name || 'My Team'} · ${roster.length}/${context.rosterSize}`;
    const editButton = document.createElement('button');
    editButton.type = 'button';
    editButton.className = 'secondary workspace-roster-edit';
    editButton.textContent = 'Edit team name';
    rosterHeading.append(editButton);
  }
  body.querySelectorAll('[data-draft-round]').forEach((button) => button.addEventListener('click', () => {
    selectedDraftRound = Number(button.dataset.draftRound);
    renderMyTeam(context, data, score, assignmentMap, memberByTeam, refresh);
  }));
  body.querySelectorAll('[data-draft-pool-filter]').forEach((button) => button.addEventListener('click', () => {
    draftPoolFilter = button.dataset.draftPoolFilter;
    const list = body.querySelector('.workspace-available-list');
    if (list) list.scrollTop = 0;
    renderMyTeam(context, data, score, assignmentMap, memberByTeam, refresh);
  }));
  body.querySelectorAll('[data-position-toggle]').forEach((button) => button.addEventListener('click', () => {
    const group = button.closest('.workspace-position-group');
    const expanded = group.classList.toggle('is-collapsed') === false;
    draftPositionExpanded.set(`${context.leagueId}:${button.dataset.positionToggle}`, expanded);
    button.setAttribute('aria-expanded', String(expanded));
    button.setAttribute('aria-label', `${expanded ? 'Collapse' : 'Expand'} ${group.querySelector('h4').textContent} slots`);
  }));
  if (context.leagueStatus === 'drafting' && !context.draftTimerDisabled) updateDraftClock(data.league.draft_pick_deadline_at, null, context.draftPaused);
  else {
    clearInterval(workspaceDraftTimer);
    workspaceDraftTimer = null;
  }
  $('#toggleDraftPause')?.addEventListener('click', () => runAction(
    () => db.rpc('set_league_draft_paused', { p_league_id: context.leagueId, p_paused: !context.draftPaused }),
    refresh,
    $('#toggleDraftPause'),
  ));
  $('#startDraftFromTeam')?.addEventListener('click', () => confirmStartDraft(context));
  $('#toggleDraftReady')?.addEventListener('click', () => runAction(
    () => db.rpc('set_league_draft_ready', { p_league_id: context.leagueId, p_ready: !ownReady }),
    refresh,
    $('#toggleDraftReady'),
  ));
  $('#editMyTeam').hidden = context.leagueStatus !== 'active';
  const openTeamNameEditor = () => {
    dialog(`<p class="eyebrow">Team settings</p><h2>Edit team name</h2><label>Team name<input id="workspaceTeamName" maxlength="80" value="${safe(ownTeam.team_name || '')}"></label><div class="modal-actions"><button id="saveWorkspaceTeamName">Save</button></div>`);
    $('#saveWorkspaceTeamName').addEventListener('click', () => runAction(
      () => db.rpc('update_league_team_name', { p_league_id: context.leagueId, p_team_name: $('#workspaceTeamName').value.trim() }),
      async () => { $('#modal').close(); await refresh(); },
      $('#saveWorkspaceTeamName'),
    ));
  };
  $('#editMyTeam').onclick = context.leagueStatus === 'active' ? openTeamNameEditor : null;
  body.querySelector('.workspace-roster-edit')?.addEventListener('click', openTeamNameEditor);
  body.querySelectorAll('[data-workspace-claim]').forEach((button) => button.addEventListener('click', () => {
    const incoming = data.cast.find((member) => member.id === button.dataset.workspaceClaim);
    if (!incoming) return;
    if (context.leagueStatus === 'drafting') {
      dialog(`<div class="draft-claim-dialog"><p class="eyebrow">Round ${turn.round} · Pick #${turn.pickNumber}</p><h2>Draft ${safe(incoming.name)}?</h2><p class="sub">This selection is final and fills one of your ${context.rosterSize} roster spots.</p>${castTile(incoming)}<div class="modal-actions"><button id="cancelWorkspaceClaim" type="button" class="secondary">Keep browsing</button><button id="confirmWorkspaceClaim">Confirm pick</button></div></div>`);
      $('#cancelWorkspaceClaim').addEventListener('click', () => $('#modal').close());
      $('#confirmWorkspaceClaim').addEventListener('click', () => runAction(
        () => db.rpc('claim_league_cast_member', { p_league_id: context.leagueId, p_incoming_cast_member_id: incoming.id }),
        async () => { $('#modal').close(); selectedDraftRound = null; await refresh(); },
        $('#confirmWorkspaceClaim'),
      ));
    } else {
      dialog(`<p class="eyebrow">Free-agent claim</p><h2>Claim ${safe(incoming.name)}</h2><p class="sub">Choose one cast member from your roster to release.</p>${castTile(incoming)}<div class="workspace-release-list">${roster.map((member) => `<button class="workspace-release-choice" data-workspace-release="${member.id}">${safe(member.name)} <small>${safe(castCategory(member))}</small></button>`).join('')}</div><p id="workspaceSwapHint" class="sub"></p><div class="modal-actions"><button id="confirmWorkspaceClaim" disabled>Swap cast</button></div>`);
      let outgoingId = null;
      $('#modalBody').querySelectorAll('[data-workspace-release]').forEach((choice) => choice.addEventListener('click', () => {
        outgoingId = choice.dataset.workspaceRelease;
        $('#modalBody').querySelectorAll('[data-workspace-release]').forEach((item) => item.classList.toggle('selected', item === choice));
        const incomingCategory = castCategory(incoming);
        const outgoingCategory = castCategory(roster.find((member) => member.id === outgoingId));
        const exceedsLimit = enforceRoleBalance && incomingCategory !== 'Bonus' && teamCategoryCount(incomingCategory)
          - Number(outgoingCategory === incomingCategory) + 1 > categoryLimits[incomingCategory];
        $('#confirmWorkspaceClaim').disabled = exceedsLimit;
        $('#workspaceSwapHint').textContent = exceedsLimit
          ? `This swap would exceed your ${incomingCategory.toLowerCase()} limit of ${categoryLimits[incomingCategory]}. Choose another cast member to release.` : '';
      }));
      $('#confirmWorkspaceClaim').addEventListener('click', () => runAction(
        () => db.rpc('claim_league_cast_member', { p_league_id: context.leagueId,
          p_incoming_cast_member_id: incoming.id, p_outgoing_cast_member_id: outgoingId }),
        async () => { $('#modal').close(); await refresh(); },
        $('#confirmWorkspaceClaim'),
      ));
    }
  }));
}

async function renderWorkspaceTrades(context, data, assignmentMap, memberByTeam, refresh) {
  const center = $('#workspaceTradeCenter');
  if (!center) return;
  const requestVersion = ++tradeRequestVersion;
  const viewVersion = workspaceVersion;
  const result = await db.rpc('get_my_league_trades', { p_league_id: context.leagueId });
  if (!center.isConnected || requestVersion !== tradeRequestVersion || viewVersion !== workspaceVersion) return;
  if (result.error) {
    console.error('Could not load league trades', result.error);
    center.innerHTML = `<p>Trades could not load.</p><button id="retryWorkspaceTrades">Try again</button>`;
    center.querySelector('#retryWorkspaceTrades').addEventListener('click', () => renderWorkspaceTrades(context, data, assignmentMap, memberByTeam, refresh));
    return;
  }
  const trades = result.data || { offers: [], history: [], notifications: [] };
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const airingLock = isTradeAiringLocked(data.weeks);
  const teamName = (id) => memberByTeam.get(id)?.team_name || memberByTeam.get(id)?.display_name || 'Team';
  const castName = (id) => castById.get(id)?.name || 'Cast member';
  const ownId = context.fantasyTeamId;
  const offerCard = (offer) => {
    const mineId = offer.initiator_team_id === ownId ? offer.initiator_cast_member_id : offer.counterparty_cast_member_id;
    const theirsId = offer.initiator_team_id === ownId ? offer.counterparty_cast_member_id : offer.initiator_cast_member_id;
    const theirTeamId = offer.initiator_team_id === ownId ? offer.counterparty_team_id : offer.initiator_team_id;
    const waitingForMe = offer.awaiting_team_id === ownId;
    const hoursLeft = Math.max(0, Math.ceil((new Date(offer.expires_at).getTime() - Date.now()) / 3600000));
    return `<article class="workspace-trade-card"><small>${offer.status === 'countered' ? 'Counter offer' : 'Trade offer'} · ${waitingForMe ? 'Your response' : `Waiting for ${safe(teamName(theirTeamId))}`} · ${hoursLeft}h left</small><div class="workspace-trade-swap">${castTile(castById.get(mineId) || { name: castName(mineId), role: '' })}<span>⇄</span>${castTile(castById.get(theirsId) || { name: castName(theirsId), role: '' })}</div><div class="workspace-trade-actions">${waitingForMe ? `<button data-workspace-trade="accept:${offer.id}" ${airingLock ? 'disabled' : ''}>Accept</button><button class="secondary" data-workspace-trade="counter:${offer.id}" ${airingLock ? 'disabled' : ''}>Counter</button><button class="secondary" data-workspace-trade="deny:${offer.id}">Deny</button>` : `<button class="secondary" data-workspace-trade="cancel:${offer.id}">Cancel</button>`}</div></article>`;
  };
  const eventCard = (event, notification = false) => `<article class="workspace-trade-card"><small>${safe(event.event_type)} · ${new Date(event.event_at).toLocaleDateString()}</small><b>${safe(event.initiator_cast_member_name)} ⇄ ${safe(event.counterparty_cast_member_name)}</b>${notification ? `<button class="secondary" data-dismiss-workspace-trade="${event.id}">Dismiss</button>` : ''}</article>`;
  center.innerHTML = `<div class="workspace-section-head"><div><p class="eyebrow">Manager tools</p><h3>Trades</h3></div><button id="proposeWorkspaceTrade" ${airingLock ? 'disabled' : ''}>${airingLock ? 'Airing lock' : 'Propose trade'}</button></div>${airingLock ? '<p class="sub">Trades pause from two hours before the show until two hours after. You can still deny or cancel offers.</p>' : ''}<div class="workspace-trade-tabs"><button data-workspace-trade-tab="active" class="${tradeTab === 'active' ? 'selected' : ''}">Active ${(trades.offers?.length || 0) + (trades.notifications?.length || 0)}</button><button data-workspace-trade-tab="history" class="${tradeTab === 'history' ? 'selected' : ''}">History</button></div>${tradeTab === 'active' ? `${(trades.notifications || []).map((item) => eventCard(item, true)).join('')}${(trades.offers || []).map(offerCard).join('') || (trades.notifications?.length ? '' : '<p class="sub">No active trades.</p>')}` : `${(trades.history || []).map((item) => eventCard(item)).join('') || '<p class="sub">No past trades.</p>'}`}`;
  center.querySelectorAll('[data-workspace-trade-tab]').forEach((button) => button.addEventListener('click', () => {
    tradeTab = button.dataset.workspaceTradeTab;
    renderWorkspaceTrades(context, data, assignmentMap, memberByTeam, refresh);
  }));
  center.querySelector('#proposeWorkspaceTrade').addEventListener('click', () => openWorkspaceTradeBuilder(context, data, assignmentMap, memberByTeam, refresh));
  center.querySelectorAll('[data-dismiss-workspace-trade]').forEach((button) => button.addEventListener('click', () => runAction(
    () => db.rpc('dismiss_league_trade_result', { p_event_id: button.dataset.dismissWorkspaceTrade }),
    async () => renderWorkspaceTrades(context, data, assignmentMap, memberByTeam, refresh),
    button,
  )));
  center.querySelectorAll('[data-workspace-trade]').forEach((button) => button.addEventListener('click', () => {
    const [action, id] = button.dataset.workspaceTrade.split(':');
    const offer = trades.offers.find((item) => item.id === id);
    if (!offer) return;
    if (action === 'counter') return openWorkspaceCounter(context, data, assignmentMap, offer, refresh);
    const label = action === 'accept' ? 'Accept this trade?' : action === 'deny' ? 'Deny this trade?' : 'Cancel your offer?';
    dialog(`<h2>${label}</h2><p class="sub">${safe(castName(offer.initiator_cast_member_id))} ⇄ ${safe(castName(offer.counterparty_cast_member_id))}</p><button id="confirmWorkspaceTradeAction" class="${action === 'deny' ? 'danger' : ''}">${action === 'accept' ? 'Accept' : action === 'deny' ? 'Deny' : 'Cancel offer'}</button>`);
    $('#confirmWorkspaceTradeAction').addEventListener('click', () => runAction(
      () => db.rpc('respond_to_league_trade', { p_offer_id: id, p_action: action }),
      async () => { $('#modal').close(); await refresh(); },
      $('#confirmWorkspaceTradeAction'),
    ));
  }));
}

function tradeRoleLimitIssue(context, data, assignmentMap, firstTeamId, firstCastId, secondTeamId, secondCastId) {
  if (context.leagueId === defaultLeagueId) return '';
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const limits = leagueCategoryLimits(data);
  for (const [teamId, outgoingId, incomingId] of [
    [firstTeamId, firstCastId, secondCastId],
    [secondTeamId, secondCastId, firstCastId],
  ]) {
    const incoming = castById.get(incomingId);
    const outgoing = castById.get(outgoingId);
    const role = incoming && castCategory(incoming);
    if (role !== 'Pro' && role !== 'Star') continue;
    const current = data.cast.filter((member) => assignmentMap.get(member.id) === teamId
      && castCategory(member) === role).length;
    if (current - Number(outgoing && castCategory(outgoing) === role) + 1 > limits[role]) {
      return `This trade would exceed a team's current active ${role.toLowerCase()} limit of ${limits[role]}. Choose a Bonus cast member instead.`;
    }
  }
  return '';
}

function openWorkspaceTradeBuilder(context, data, assignmentMap, memberByTeam, refresh) {
  const own = data.cast.filter((member) => assignmentMap.get(member.id) === context.fantasyTeamId);
  const others = data.teams.filter((team) => team.id !== context.fantasyTeamId);
  const state = { mine: null, team: null, theirs: null };
  const render = () => {
    const theirs = state.team ? data.cast.filter((member) => assignmentMap.get(member.id) === state.team) : [];
    const issue = state.mine && state.team && state.theirs ? tradeRoleLimitIssue(context, data, assignmentMap,
      context.fantasyTeamId, state.mine, state.team, state.theirs) : '';
    dialog(`<p class="eyebrow">New trade</p><h2>Propose a Trade</h2><p class="sub">Choose one of your cast members, another team, and the cast member you want. The other manager has 48 hours.</p><h3>You send</h3><div class="workspace-trade-picker">${own.map((member) => `<button class="${state.mine === member.id ? 'selected' : ''}" data-builder-mine="${member.id}">${castTile(member, '', 'span')}</button>`).join('')}</div><h3>Trade with</h3><div class="workspace-trade-team-picker">${others.map((team) => `<button class="${state.team === team.id ? 'selected' : ''}" data-builder-team="${team.id}">${safe(team.team_name || memberByTeam.get(team.id)?.display_name || 'Team')}</button>`).join('')}</div>${state.team ? `<h3>You receive</h3><div class="workspace-trade-picker">${theirs.map((member) => `<button class="${state.theirs === member.id ? 'selected' : ''}" data-builder-theirs="${member.id}">${castTile(member, '', 'span')}</button>`).join('')}</div>` : ''}${issue ? `<p class="sub" role="alert">${safe(issue)}</p>` : ''}<div class="modal-actions"><button id="sendWorkspaceTrade" ${state.mine && state.theirs && !issue ? '' : 'disabled'}>Send Trade</button></div>`);
    $('#modalBody').querySelectorAll('[data-builder-mine]').forEach((button) => button.addEventListener('click', () => { state.mine = button.dataset.builderMine; render(); }));
    $('#modalBody').querySelectorAll('[data-builder-team]').forEach((button) => button.addEventListener('click', () => { state.team = button.dataset.builderTeam; state.theirs = null; render(); }));
    $('#modalBody').querySelectorAll('[data-builder-theirs]').forEach((button) => button.addEventListener('click', () => { state.theirs = button.dataset.builderTheirs; render(); }));
    $('#sendWorkspaceTrade').addEventListener('click', () => runAction(
      () => db.rpc('request_league_trade', { p_league_id: context.leagueId,
        p_my_cast_member_id: state.mine, p_requested_cast_member_id: state.theirs }),
      async () => { $('#modal').close(); await refresh(); },
      $('#sendWorkspaceTrade'),
    ));
  };
  render();
}

function openWorkspaceCounter(context, data, assignmentMap, offer, refresh) {
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const state = { side: null, replacement: null };
  const render = () => {
    const replacementTeamId = state.side === 'initiator' ? offer.initiator_team_id : offer.counterparty_team_id;
    const originalId = state.side === 'initiator' ? offer.initiator_cast_member_id : offer.counterparty_cast_member_id;
    const options = state.side ? data.cast.filter((member) => assignmentMap.get(member.id) === replacementTeamId && member.id !== originalId) : [];
    const sideCard = (side, castId) => `<button type="button" class="workspace-counter-side ${state.side === side ? 'selected' : ''}" data-counter-side="${side}" ${state.replacement ? 'disabled' : ''}>${castTile(castById.get(state.side === side && state.replacement ? state.replacement : castId) || { name: 'Cast member', role: '' }, '', 'span')}</button>`;
    const initiatorCastId = state.side === 'initiator' && state.replacement ? state.replacement : offer.initiator_cast_member_id;
    const counterpartyCastId = state.side === 'counterparty' && state.replacement ? state.replacement : offer.counterparty_cast_member_id;
    const issue = state.replacement ? tradeRoleLimitIssue(context, data, assignmentMap,
      offer.initiator_team_id, initiatorCastId, offer.counterparty_team_id, counterpartyCastId) : '';
    dialog(`<p class="eyebrow">Trade response</p><h2>Counter Offer</h2><p class="sub">Select the cast member to replace. Change one side only.</p><div class="workspace-counter-swap">${sideCard('initiator', offer.initiator_cast_member_id)}<span>⇄</span>${sideCard('counterparty', offer.counterparty_cast_member_id)}</div>${state.replacement ? '<button id="clearWorkspaceCounter" class="secondary">× Remove change</button>' : ''}${state.side && !state.replacement ? `<h3>Choose a replacement</h3><div class="workspace-trade-picker">${options.map((member) => `<button data-counter-replacement="${member.id}">${castTile(member, '', 'span')}</button>`).join('')}</div>` : ''}${issue ? `<p class="sub" role="alert">${safe(issue)}</p>` : ''}<div class="modal-actions"><button id="sendWorkspaceCounter" ${state.replacement && !issue ? '' : 'disabled'}>Send counter</button></div>`);
    $('#modalBody').querySelectorAll('[data-counter-side]').forEach((button) => button.addEventListener('click', () => { state.side = button.dataset.counterSide; render(); }));
    $('#modalBody').querySelectorAll('[data-counter-replacement]').forEach((button) => button.addEventListener('click', () => { state.replacement = button.dataset.counterReplacement; render(); }));
    $('#clearWorkspaceCounter')?.addEventListener('click', () => { state.side = null; state.replacement = null; render(); });
    $('#sendWorkspaceCounter').addEventListener('click', () => runAction(
      () => db.rpc('respond_to_league_trade', { p_offer_id: offer.id, p_action: 'counter',
        p_replace_side: state.side, p_replacement_cast_member_id: state.replacement }),
      async () => { $('#modal').close(); await refresh(); },
      $('#sendWorkspaceCounter'),
    ));
  };
  render();
}

function openWorkspaceDanceDetail(data, score, assignmentMap, memberByTeam, week, dance, backToProfile = null) {
  const castById = new Map(data.cast.map((cast) => [cast.id, cast]));
  const pair = data.pairs.find((item) => item.id === dance.partnership_id);
  const star = castById.get(pair?.star_id);
  const pro = castById.get(pair?.pro_id);
  const scores = data.scores.filter((item) => item.dance_id === dance.id);
  const appearances = data.appearances.filter((item) => item.dance_id === dance.id);
  const scoreTotal = scores.reduce((sum, item) => sum + Number(item.score || 0), 0);
  const participants = [...new Map([star, pro, ...appearances.map((item) => castById.get(item.cast_member_id))]
    .filter(Boolean).map((cast) => [cast.id, cast])).values()];
  const rows = participants.map((cast) => {
    const snapshot = week.is_complete ? score.snapshotByKey.get(`${week.id}:${cast.id}`) : null;
    const teamId = snapshot?.fantasy_team_id ?? assignmentMap.get(cast.id);
    const team = memberByTeam.get(teamId);
    const role = snapshot?.cast_role || cast.role;
    const rate = snapshot?.appearance_points ?? (cast.is_hough ? score.rateByName.get('Hough')
      : role === 'Surprise' ? cast.custom_appearance_points : score.rateByName.get(role)) ?? 0;
    const appearanceCount = appearances.filter((item) => item.cast_member_id === cast.id).length;
    return { member: cast, role: role === 'DWTS Next Pro' ? 'Next Pro' : role,
      teamId, teamName: snapshot?.team_name || team?.team_name || team?.display_name || 'Available cast',
      points: ((cast.id === star?.id || cast.id === pro?.id) && dance.kind === 'competitive' ? scoreTotal : 0)
        + appearanceCount * Number(rate || 0) };
  }).sort((a, b) => b.points - a.points || a.member.name.localeCompare(b.member.name));
  const totals = new Map();
  rows.forEach((row) => { if (row.teamId) totals.set(row.teamName, (totals.get(row.teamName) || 0) + row.points); });
  const title = star && pro ? `${star.name} & ${pro.name}` : dance.name || 'Performance';
  dialog(`${backToProfile ? '<div class="modal-back-row"><button class="profile-back-button secondary" id="danceBackToProfile" type="button" aria-label="Back to profile">← Back</button></div>' : ''}${danceDetail({ kind: dance.kind, title, danceType: dance.dance_type, song: dance.song, photos: danceImagesFor(week.number, title), weekNumber: week.number,
    scores, scoreImage: (value) => `Images/Judges Scores/${Number(value)}.png?v=20260921-optimized`,
    judgePhoto: judgePortraitFor,
    weeklyPrediction: weeklyPredictionFor(star?.id, week,
      activePartnershipPredictionRows(data.marketPredictions || [], data.pairs, data.cast)),
    teams: [...totals].sort((a, b) => b[1] - a[1]).map(([name, points]) => ({ name, points })),
    castRows: rows, imageFor: castImage })}`);
  $('#danceBackToProfile')?.addEventListener('click', backToProfile);
  bindDanceGallery($('#modalBody'));
  $('#modalBody').querySelectorAll('[data-dance-cast-profile]').forEach((button) => button.addEventListener('click', () => {
    const row = rows.find((item) => item.member.id === button.dataset.danceCastProfile);
    if (row) openWorkspaceCastProfile(row.member, row.teamName,
      () => openWorkspaceDanceDetail(data, score, assignmentMap, memberByTeam, week, dance, backToProfile), 'dance');
  }));
}

function renderDances(context, data, score, assignmentMap, memberByTeam) {
  const visibleWeeks = data.weeks.filter((week) => week.is_complete || week.number <= (data.weeks.findLast((item) => item.is_complete)?.number || 0) + 1);
  const tabs = $('#weekTabs');
  const content = $('#scoreDeskContent');
  if (!visibleWeeks.length) { tabs.innerHTML = ''; content.innerHTML = '<div class="card pad">No dances have been scheduled.</div>'; return; }
  if (!visibleWeeks.some((week) => week.id === selectedDanceWeekId)) selectedDanceWeekId = visibleWeeks.at(-1).id;
  tabs.innerHTML = visibleWeeks.map((week) => `<button type="button" class="${week.id === selectedDanceWeekId ? 'selected' : ''}" data-workspace-week="${week.id}">Week ${week.number}</button>`).join('');
  tabs.querySelectorAll('[data-workspace-week]').forEach((button) => button.addEventListener('click', () => {
    selectedDanceWeekId = button.dataset.workspaceWeek;
    renderDances(context, data, score, assignmentMap, memberByTeam);
  }));
  const week = visibleWeeks.find((item) => item.id === selectedDanceWeekId);
  const weekDances = data.dances.filter((dance) => dance.week_id === week.id);
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const pairById = new Map(data.pairs.map((pair) => [pair.id, pair]));
  const nameFor = (castId) => castById.get(castId)?.name || 'Cast member';
  const competitiveCount = weekDances.filter((dance) => dance.kind === 'competitive').length;
  const airDate = week.air_date ? new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })
    .format(new Date(`${week.air_date}T00:00:00Z`)) : '';
  content.innerHTML = `<div class="score-week-head card"><div class="week-heading"><p class="eyebrow">Week ${week.number}</p><div class="week-title-line"><h2>${safe(week.title || (week.theme ? `${week.theme} Week` : `Week ${week.number}`))}</h2></div><p class="sub">${safe([airDate, week.is_complete ? 'Week complete' : 'Upcoming week'].filter(Boolean).join(' · '))}</p></div><div class="week-summary"><span>${competitiveCount} competitive</span>${weekDances.length > competitiveCount ? `<span>${weekDances.length - competitiveCount} performances</span>` : ''}<span class="${week.is_complete ? 'week-complete' : 'week-upcoming'}">${week.is_complete ? 'Complete' : 'Upcoming'}</span></div></div><div class="dance-list">${weekDances.map((dance) => {
    const pair = pairById.get(dance.partnership_id);
    const names = pair ? `${nameFor(pair.star_id)} & ${nameFor(pair.pro_id)}` : dance.name || 'Performance';
    const judges = data.scores.filter((item) => item.dance_id === dance.id);
    const castMembers = data.appearances.filter((item) => item.dance_id === dance.id)
      .map((appearance) => castById.get(appearance.cast_member_id)).filter(Boolean);
    const castNames = castMembers.map((member) => member.name);
    const proName = pair ? nameFor(pair.pro_id).trim().split(/\s+/) : [];
    const shortTitle = pair && proName.length > 1
      ? `${nameFor(pair.star_id)} & ${proName.slice(0, -1).join(' ')}` : '';
    return danceCard({ id: dance.id, kind: dance.kind, title: names, shortTitle,
      photos: danceImagesFor(week.number, names), cardPhoto: danceCardPhotoFor(week.number, names),
      poster: Number(week.number) <= 2,
      weekNumber: week.number,
      danceType: dance.dance_type, song: dance.song, scores: judges, castNames, castMembers,
      imageFor: castImage,
      scoreImage: (value) => `Images/Judges Scores/${Number(value)}.png?v=20260921-optimized`,
      judgePhoto: judgePortraitFor,
      pending: false, weeklyPrediction: weeklyPredictionFor(pair?.star_id, week,
        activePartnershipPredictionRows(data.marketPredictions || [], data.pairs, data.cast)) });
  }).join('') || '<div class="card pad">No dances recorded for this week.</div>'}</div>`;
  danceSongResizeObserver?.disconnect();
  fitDanceCardNames(content);
  fitDanceSongLabels(content);
  if (typeof ResizeObserver !== 'undefined') {
    danceSongResizeObserver = new ResizeObserver(() => {
      fitDanceCardNames(content);
      fitDanceSongLabels(content);
    });
    content.querySelectorAll('.dance-row').forEach((row) => danceSongResizeObserver.observe(row));
    content.querySelectorAll('.dance-row .dance-details').forEach((details) => danceSongResizeObserver.observe(details));
  }
  content.querySelectorAll('[data-dance-detail]').forEach((button) => {
    const open = () => openWorkspaceDanceDetail(data, score, assignmentMap, memberByTeam, week,
      weekDances.find((item) => item.id === button.dataset.danceDetail));
    button.addEventListener('click', open);
    button.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

async function renderLeague(context, data, assignmentMap, memberByTeam, score, refresh) {
  const renderVersion = workspaceVersion;
  const preparing = context.leagueStatus === 'setup' || context.leagueStatus === 'drafting';
  $('#league').classList.toggle('is-league-setup', preparing);
  $('#league .league-title-head .eyebrow').textContent = preparing ? 'League Draft' : 'League View';
  $('#league .league-title-head .sub').textContent = preparing
    ? 'Review managers, draft settings, the cast pool, and scoring rules.'
    : 'Browse teams, cast, and scoring rules.';
  $('#leagueTeamsPane h2').textContent = context.leagueStatus === 'setup' ? 'Managers' : 'Fantasy Teams';
  $('#leagueTeamsPane .sub').textContent = context.leagueStatus === 'setup'
    ? 'Invite friends and see who is ready for the draft.' : 'View every team and its current lineup.';
  $('#leagueRosterPane > .splithead h2').textContent = preparing ? 'Cast Pool' : 'Cast Roster';
  $('#leagueRosterPane > .splithead .sub').textContent = preparing
    ? 'Explore the cast before drafting begins.' : 'Select anyone to view their profile and season stats.';
  $('#leagueName').textContent = context.leagueName;
  $('#leagueTeamCount').textContent = data.teams.length;
  $('#leagueCastCount').textContent = data.cast.length;
  $('#leagueAvailableCount').textContent = data.cast.length - assignmentMap.size;
  $('#league .workspace-league-draft-banner')?.remove();
  if (context.leagueStatus === 'drafting') {
    const turn = draftTurn(data.order, data.picks, context.rosterSize);
    const banner = document.createElement('div');
    banner.className = 'workspace-league-draft-banner';
    banner.innerHTML = `<div><p class="eyebrow">${context.draftPaused ? 'Draft paused' : 'Draft in progress'} · Round ${turn?.round || context.rosterSize}</p><strong>${context.draftAiringLocked ? 'On hold for the show' : context.draftPaused ? 'The clock is stopped' : `${safe(memberByTeam.get(turn?.teamId)?.display_name || 'The next manager')} is on the clock`}</strong><small>${data.picks.length} of ${data.order.length * context.rosterSize} picks complete</small></div><button type="button" id="leagueOpenDraft">Open draft</button>`;
    $('#league .league-at-a-glance').after(banner);
    banner.querySelector('button').addEventListener('click', () => $('#myTeamNav').click());
  }
  // The original league's name is still maintained through Score Desk's
  // legacy settings during the reversible transition.
  $('#editLeagueName').hidden = context.leagueRole !== 'owner' || context.leagueId === defaultLeagueId;
  $('#editLeagueName').onclick = () => openLeagueSettings(context, refresh);
  const teamsHeading = $('#leagueTeamsPane .splithead');
  teamsHeading.querySelector('#manageLeagueInvites')?.remove();
  if (context.leagueRole === 'owner' && context.leagueStatus === 'setup') {
    const inviteButton = document.createElement('button');
    inviteButton.id = 'manageLeagueInvites';
    inviteButton.textContent = 'Invite';
    inviteButton.addEventListener('click', () => openInviteManager(context, refresh));
    teamsHeading.append(inviteButton);
  }
  const readyManagerIds = new Set(data.readiness.filter((item) => item.ready_at).map((item) => item.user_id));
  $('#commissionerTeamResults').innerHTML = data.teams.map((team) => {
    const member = memberByTeam.get(team.id);
    const roster = data.cast.filter((cast) => assignmentMap.get(cast.id) === team.id);
    const managerName = member?.display_name || team.manager_name;
    const teamName = team.team_name || `${managerName.split(' ')[0]}'s Team`;
    return teamCard({ id: team.id, manager: managerName, name: teamName,
      roster: roster.map((cast) => ({ name: cast.name, role: cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role })),
      emptyMessage: context.leagueStatus === 'setup' ? member?.member_role === 'owner' ? 'Commissioner' : readyManagerIds.has(member?.user_id) ? 'Ready to draft' : 'Not ready yet' : context.leagueStatus === 'drafting' ? 'Waiting for first pick' : 'No cast on this team',
      footerHtml: context.leagueRole === 'owner' && context.leagueStatus === 'setup' && member?.member_role === 'member'
        ? `<button class="secondary workspace-remove-manager" data-remove-member="${member.user_id}">Remove manager</button>` : '' });
  }).join('');
  $('#commissionerTeamResults').querySelectorAll('[data-team-detail]').forEach((card) => {
    const open = () => openWorkspaceTeamDetail(card.dataset.teamDetail);
    card.addEventListener('click', (event) => { if (!event.target.closest('button')) open(); });
    card.addEventListener('keydown', (event) => { if (event.target.closest('button')) return; if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
  const rosterResults = $('#rosterResults');
  const drawCast = () => {
    const term = $('#rosterSearch').value.trim().toLowerCase();
    const matchesFilter = (cast) => workspaceRosterFilter === 'all'
      || (workspaceRosterFilter === 'pros' && ['Pro', 'Eliminated Pro', 'DWTS Next Pro'].includes(cast.role))
      || (workspaceRosterFilter === 'stars' && ['Star', 'Eliminated Star'].includes(cast.role))
      || (workspaceRosterFilter === 'bonus' && !['Pro', 'Eliminated Pro', 'DWTS Next Pro', 'Star', 'Eliminated Star'].includes(cast.role));
    rosterResults.innerHTML = data.cast.filter((cast) => cast.name.toLowerCase().includes(term) && matchesFilter(cast)).map((cast) => {
      const partner = data.pairs.find((pair) => pair.star_id === cast.id || pair.pro_id === cast.id);
      const partnerId = partner?.star_id === cast.id ? partner.pro_id : partner?.star_id;
      const partnerName = data.cast.find((item) => item.id === partnerId)?.name;
      const teamName = memberByTeam.get(assignmentMap.get(cast.id))?.team_name || 'Available';
      const eliminated = data.weeks.find((week) => week.id === cast.eliminated_week_id);
      const detail = [cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role, partnerName, teamName, eliminated ? `Eliminated Week ${eliminated.number}` : null].filter(Boolean).join(' · ');
      return castRosterRow({ id: cast.id, name: cast.name, roleDetails: detail,
        image: castImage(cast), position: cast.image_position ?? 50 });
    }).join('') || '<p class="sub">No matching cast members.</p>';
    rosterResults.querySelectorAll('[data-cast-detail]').forEach((button) => {
      const open = () => {
      const cast = data.cast.find((item) => item.id === button.dataset.castDetail);
      openWorkspaceCastProfile(cast, memberByTeam.get(assignmentMap.get(cast.id))?.team_name || 'Available cast');
      };
      button.addEventListener('click', open);
      button.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
    });
  };
  $('#rosterSearch').oninput = drawCast;
  document.querySelectorAll('[data-roster-filter]').forEach((button) => {
    button.classList.toggle('selected', button.dataset.rosterFilter === workspaceRosterFilter);
    button.onclick = () => {
      workspaceRosterFilter = button.dataset.rosterFilter;
      document.querySelectorAll('[data-roster-filter]').forEach((item) => item.classList.toggle('selected', item === button));
      drawCast();
    };
  });
  drawCast();
  const rateByRole = new Map(data.roles.map((role) => [role.id, role]));
  $('#roleRatesContent').innerHTML = roleRatesTable(data.rates.map((rate) => ({
    name: rateByRole.get(rate.role_id)?.name || 'Role', appearance_points: rate.appearance_points })), { secondaryLeague: true });
  $('#editRules').hidden = context.leagueRole !== 'owner';
  $('#editRules').onclick = () => {
    dialog(`<h2>Edit Appearance Rates</h2><p class="sub">These points per recorded dance appearance belong only to ${safe(context.leagueName)}. Surprise cast scores at its normal Bonus role rate plus 2.</p><div class="rate-editor">${data.rates.filter((rate) => rate.appearance_points != null).map((rate) => `<label>${safe(rateByRole.get(rate.role_id)?.name || 'Role')}<input type="number" min="0" max="99" step="1" inputmode="numeric" data-workspace-rate="${safe(rateByRole.get(rate.role_id)?.name || '')}" value="${rate.appearance_points}"></label>`).join('')}</div><div class="modal-actions"><button id="saveWorkspaceRates">Save rules</button></div>`);
    $('#saveWorkspaceRates').addEventListener('click', () => runAction(
      () => db.rpc('update_league_role_rates', { p_league_id: context.leagueId,
        p_rates: [...$('#modalBody').querySelectorAll('[data-workspace-rate]')].map((input) => ({ name: input.dataset.workspaceRate, appearance_points: Number(input.value) })) }),
      async () => { $('#modal').close(); await refresh(); },
      $('#saveWorkspaceRates'),
    ));
  };
  $('#league').querySelector('#workspacePeople')?.remove();
  $('#commissionerTeamResults').querySelectorAll('[data-remove-member]').forEach((button) => button.addEventListener('click', () => {
    const member = data.members.find((item) => item.user_id === button.dataset.removeMember);
    dialog(`<h2>Remove ${safe(member?.display_name || 'member')}?</h2><p class="sub">This removes their team from the league before the draft starts.</p><button id="confirmRemoveMember" class="danger">Remove member</button>`);
    $('#confirmRemoveMember').addEventListener('click', () => runAction(
      () => db.rpc('remove_league_member', { p_league_id: context.leagueId, p_user_id: button.dataset.removeMember }),
      async () => { $('#modal').close(); await refresh(); },
      $('#confirmRemoveMember'),
    ));
  }));
  if (context.leagueRole === 'owner' && context.leagueStatus === 'setup') {
    const pending = await loadPendingInvites(context.leagueId);
    if (renderVersion === workspaceVersion && $('#manageLeagueInvites')) {
      $('#manageLeagueInvites').textContent = pending.length ? 'Manage Invites' : 'Invite';
    }
  }
}

async function loadPendingInvites(leagueId) {
  const result = await db.from('league_invites').select('id,invitee_id,expires_at')
    .eq('league_id', leagueId).eq('status', 'pending').gt('expires_at', new Date().toISOString());
  if (result.error) { console.error(result.error); return []; }
  const pending = result.data || [];
  if (!pending.length) return pending;
  const people = await db.from('profile_directory').select('user_id,username,display_name,avatar_url').in('user_id', pending.map((item) => item.invitee_id));
  const personById = new Map((people.data || []).map((person) => [person.user_id, person]));
  return pending.map((item) => ({ ...item, ...personById.get(item.invitee_id), username: personById.get(item.invitee_id)?.username || 'member' }));
}

function confirmStartDraft(context) {
  dialog(`<p class="eyebrow">Final confirmation</p><h2>Start the draft?</h2><p class="sub">The order will be randomized once. ${context.memberCount} managers will each draft ${context.rosterSize} cast members in snake order. New members cannot join after it starts.</p><label class="workspace-untimed-choice"><input id="disableDraftTimer" type="checkbox"><span><b>Disable timer &amp; autodraft</b><small>Managers can take as long as they need to pick. No random cast will be selected.</small></span></label><div class="modal-actions"><button id="cancelStartDraft" type="button" class="secondary">Cancel</button><button id="confirmStartDraft">Start draft</button></div>`);
  $('#cancelStartDraft').addEventListener('click', () => $('#modal').close());
  $('#confirmStartDraft').addEventListener('click', () => runAction(
    () => db.rpc('start_league_draft', { p_league_id: context.leagueId,
      p_disable_timer: $('#disableDraftTimer').checked }),
    async () => { $('#modal').close(); selectedDraftRound = 1; await renderSecondaryLeague(context, { silent: true }); },
    $('#confirmStartDraft'),
  ));
}

function openLeagueSettings(context, refresh) {
  const isSetup = context.leagueStatus === 'setup';
  const rosterOptions = isSetup ? `<p class="sub workspace-roster-help">Roster size is set automatically: ${context.rosterSize} picks per team for ${context.memberCount} manager${context.memberCount === 1 ? '' : 's'}. It adjusts as managers join.</p>` : '';
  dialog(`<p class="eyebrow">League settings</p><h2>Edit ${safe(context.leagueName)}</h2><label>League name<input id="workspaceLeagueName" maxlength="80" value="${safe(context.leagueName)}"></label>${rosterOptions}<div class="modal-actions"><button id="saveWorkspaceSettings">Save changes</button></div><div class="workspace-danger-zone"><h3>Delete league</h3><p class="sub">Permanently remove this league, its teams, invitations, draft, trades, and scoring history for every manager. This cannot be undone.</p><button id="deleteWorkspaceLeague" class="danger">Delete league</button></div>`);
  $('#saveWorkspaceSettings').addEventListener('click', () => runAction(
    () => db.rpc('update_league_workspace', { p_league_id: context.leagueId,
      p_name: $('#workspaceLeagueName').value.trim(),
      p_roster_size: isSetup ? null : context.rosterSize,
      p_auto_roster: isSetup ? true : null }),
    async () => { $('#modal').close(); location.reload(); },
    $('#saveWorkspaceSettings'),
  ));
  $('#deleteWorkspaceLeague')?.addEventListener('click', () => {
    dialog(`<h2>Delete ${safe(context.leagueName)}?</h2><p class="sub">This permanently removes the league for every manager, including its teams, invitations, draft, trades, and scoring history. This cannot be undone.</p><div class="modal-actions"><button id="cancelDeleteLeague" type="button" class="secondary">Cancel</button><button id="confirmDeleteLeague" type="button" class="danger">Delete league permanently</button></div>`);
    $('#cancelDeleteLeague').focus();
    $('#cancelDeleteLeague').addEventListener('click', () => $('#modal').close());
    $('#confirmDeleteLeague').addEventListener('click', () => runAction(
      () => db.rpc('delete_fantasy_league', { p_league_id: context.leagueId }),
      async () => {
        localStorage.removeItem('mirrorball-active-league');
        location.assign(`${location.pathname}#standings`);
      }, $('#confirmDeleteLeague'),
    ));
  });
}

function openInviteManager(context, refresh) {
  dialog(`<p class="eyebrow">${safe(context.leagueName)}</p><h2>Invite Players</h2><p class="sub">${context.memberCount >= 5 ? 'This league is full. You can still review pending invitations.' : 'Share the league invitation or invite someone directly by exact username.'}</p><form id="inviteUsernameForm" class="workspace-exact-invite-form" novalidate><label for="inviteUsernameSearch">Invite by username</label><div class="workspace-exact-invite-row"><input id="inviteUsernameSearch" autocomplete="off" autocapitalize="none" spellcheck="false" placeholder="Exact @username" maxlength="21" ${context.memberCount >= 5 ? 'disabled' : ''}><button id="inviteExactUsername" type="submit" ${context.memberCount >= 5 ? 'disabled' : ''}>Invite</button></div><p id="inviteUsernameStatus" class="sub" role="status"></p></form><div id="generatedInviteLink" aria-live="polite"><p class="sub">Loading invite code…</p></div><div id="pendingLeagueInvites"></div>`);
  const drawPending = async () => {
    const pending = await loadPendingInvites(context.leagueId);
    const container = $('#pendingLeagueInvites');
    if (!container) return;
    container.innerHTML = pending.length ? `<section class="workspace-pending-invites"><div class="workspace-pending-head"><h3>Pending invites</h3><span>${pending.length}</span></div><div class="workspace-pending-list">${pending.map((invite) => `<div class="workspace-pending-invite"><span class="workspace-invite-avatar">${invite.avatar_url ? `<img src="${safe(invite.avatar_url)}" alt="">` : safe((invite.display_name || invite.username).charAt(0).toUpperCase())}</span><span class="workspace-pending-person"><b>${safe(invite.display_name || invite.username)}</b><small>@${safe(invite.username)} · Awaiting response</small></span><button class="secondary" data-cancel-invite="${invite.id}" aria-label="Cancel invitation for ${safe(invite.username)}">Cancel</button></div>`).join('')}</div></section>` : '';
    $('#manageLeagueInvites') && ($('#manageLeagueInvites').textContent = pending.length ? 'Manage Invites' : 'Invite');
    container.querySelectorAll('[data-cancel-invite]').forEach((button) => button.addEventListener('click', () => runAction(
      () => db.rpc('cancel_league_invite', { p_invite_id: button.dataset.cancelInvite }),
      drawPending, button,
    )));
  };
  drawPending();
  let currentInvite = null;
  let inviteRefreshTimer = null;
  $('#modal').addEventListener('close', () => clearTimeout(inviteRefreshTimer), { once: true });
  const inviteUrl = () => {
    const url = new URL(location.href);
    url.search = '';
    url.searchParams.set('join', currentInvite.token);
    url.hash = '#standings';
    return url.toString();
  };
  const inviteMessage = () => {
    const inviter = context.firstName || context.displayName || context.username || 'A friend';
    return `${inviteUrl()}\n${inviter} invited you to join ${context.leagueName} on DWTS Fantasy League!\nInvite code: ${currentInvite.code}\n\nOpen the link and sign in, or enter the code on the site to join.`;
  };
  const loadInvite = async (refreshCode = false) => {
    const container = $('#generatedInviteLink');
    if (!container) return;
    clearTimeout(inviteRefreshTimer);
    container.innerHTML = '<p class="sub">Loading invite code…</p>';
    const { data, error } = await db.rpc('get_league_invite', {
      p_league_id: context.leagueId, p_refresh: refreshCode,
    });
    if (!container.isConnected) return;
    if (error) {
      container.innerHTML = `<p class="sub">Couldn’t load the invitation: ${safe(errorMessage(error))}</p><button id="retryInviteCode" type="button" class="secondary">Try again</button>`;
      $('#retryInviteCode').onclick = () => loadInvite();
      return;
    }
    currentInvite = data;
    const expires = new Date(data.expires_at).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
    container.innerHTML = `<div class="workspace-invite-share"><div class="workspace-invite-code-head"><span><small>Invite code</small><strong>${safe(data.code)}</strong></span></div><p class="sub">Link and code refresh every 48 hours · Expires ${safe(expires)}</p><div class="workspace-invite-link-actions"><button id="refreshInviteCode" type="button" class="secondary" ${context.memberCount >= 5 ? 'disabled' : ''}>Refresh code</button><button id="copyInviteLink" type="button" class="secondary" ${context.memberCount >= 5 ? 'disabled' : ''}>Copy link</button><button id="shareInvite" type="button" ${context.memberCount >= 5 ? 'disabled' : ''}>Share</button></div><p id="inviteShareStatus" class="sub" role="status"></p></div>`;
    inviteRefreshTimer = setTimeout(() => {
      if (container.isConnected && $('#modal')?.open) loadInvite();
    }, Math.max(1000, new Date(data.expires_at).getTime() - Date.now() + 250));
    $('#refreshInviteCode').onclick = () => loadInvite(true);
    const copyInviteLink = async () => {
      if (new Date(currentInvite.expires_at) <= new Date()) {
        await loadInvite();
        if ($('#inviteShareStatus')) $('#inviteShareStatus').textContent = 'Your invite refreshed. Select Copy link again.';
        return;
      }
      try {
        await navigator.clipboard.writeText(inviteUrl());
        $('#inviteShareStatus').textContent = 'Invite link copied.';
      } catch (copyError) {
        $('#inviteShareStatus').textContent = 'Clipboard unavailable. Try Share instead.';
      }
    };
    $('#copyInviteLink').onclick = copyInviteLink;
    $('#shareInvite').onclick = async () => {
      if (new Date(currentInvite.expires_at) <= new Date()) {
        await loadInvite();
        if ($('#inviteShareStatus')) $('#inviteShareStatus').textContent = 'Your invite refreshed. Select Share again.';
        return;
      }
      if (!navigator.share) {
        try {
          await navigator.clipboard.writeText(inviteMessage());
          $('#inviteShareStatus').textContent = 'Sharing is unavailable here; the invite message was copied instead.';
        } catch (copyError) {
          $('#inviteShareStatus').textContent = 'Sharing is unavailable on this device.';
        }
        return;
      }
      try { await navigator.share({ text: inviteMessage() }); }
      catch (shareError) {
        if (shareError.name !== 'AbortError') $('#inviteShareStatus').textContent = 'Sharing is unavailable. Try Copy link instead.';
      }
    };
  };
  loadInvite();
  $('#inviteUsernameForm').onsubmit = async (event) => {
    event.preventDefault();
    const username = $('#inviteUsernameSearch').value.trim().toLowerCase().replace(/^@/, '');
    const status = $('#inviteUsernameStatus');
    if (!/^[a-z0-9_]{3,20}$/.test(username)) {
      status.textContent = 'Enter the complete username (3–20 letters, numbers, or underscores).';
      return;
    }
    const button = $('#inviteExactUsername');
    button.disabled = true;
    status.textContent = 'Sending invitation…';
    const { error } = await db.rpc('invite_username', { p_league_id: context.leagueId, p_username: username });
    if (!button.isConnected) return;
    button.disabled = false;
    if (error) status.textContent = error.message || 'Could not send that invitation.';
    else {
      status.textContent = `Invitation sent to @${username}.`;
      $('#inviteUsernameSearch').value = '';
      await drawPending();
    }
  };
}

export async function renderSecondaryLeague(context, { silent = false, light = false } = {}) {
  if (!context.signedIn || (context.leagueId === defaultLeagueId && !context.useSharedWorkspace)) return;
  $('#workspaceReadOnlyBanner')?.remove();
  if (context.readOnlyWorkspacePreview) {
    const banner = document.createElement('div');
    banner.id = 'workspaceReadOnlyBanner';
    banner.className = 'card pad workspace-preview-banner';
    banner.textContent = 'Preview of the updated original league. This view is read-only; the live league has not switched.';
    $('#memberOverview').prepend(banner);
  }
  const version = ++workspaceVersion;
  ++tradeRequestVersion;
  const previousTradesRefresh = refreshCurrentWorkspaceTrades;
  refreshCurrentWorkspaceTrades = null;
  const refresh = () => renderSecondaryLeague(context, { silent: true });
  if (!silent) {
    for (const id of ['#standingsContent', '#publicTeamResults', '#commissionerTeamResults', '#scoreDeskContent']) {
      if ($(id)) $(id).innerHTML = '<div class="card pad">Loading league…</div>';
    }
  }
  try {
    // Opening an active league on an airing date records that day's roster
    // before any later changes can affect completed-week scoring.
    if (lastSnapshotLeagueId !== context.leagueId || Date.now() - lastSnapshotCheckAt >= snapshotCheckMs) {
      const snapshotRefresh = await db.rpc('refresh_my_league_snapshots', { p_league_id: context.leagueId });
      if (snapshotRefresh.error && !['PGRST202', '42883'].includes(snapshotRefresh.error.code)) {
        throw snapshotRefresh.error;
      }
      lastSnapshotLeagueId = context.leagueId;
      lastSnapshotCheckAt = Date.now();
    }
    const [data, predictions] = await Promise.all([
      loadWorkspaceData(context, { light, previous: activeWorkspaceDetail }),
      loadMarketPredictions(),
    ]);
    if (version !== workspaceVersion) return;
    data.marketPredictions = predictions;
    const refreshSignature = JSON.stringify([data, isTradeAiringLocked(data.weeks), isDraftAiringLocked(data.weeks)]);
    if (light && activeWorkspaceDetail?.context.leagueId === context.leagueId
      && activeWorkspaceDetail.refreshSignature === refreshSignature) {
      refreshCurrentWorkspaceTrades = previousTradesRefresh;
      return;
    }
    const liveContext = { ...context, leagueName: data.league.name,
      leagueStatus: data.league.status, rosterSize: data.league.roster_size,
      draftAiringLocked: isDraftAiringLocked(data.weeks),
      draftPaused: Boolean(data.league.draft_paused_at) || isDraftAiringLocked(data.weeks),
      draftTimerDisabled: Boolean(data.league.draft_timer_disabled),
      rosterSizeOverridden: data.league.roster_size_overridden,
      memberCount: data.members.length, castCount: data.cast.length,
      scoringStartsAfterWeek: data.league.scoring_starts_after_week };
    const teamNav = $('#myTeamNav');
    const teamNavLabel = liveContext.leagueStatus === 'active' ? 'My Team' : 'Draft';
    teamNav.querySelector('.nav-label').textContent = teamNavLabel;
    teamNav.setAttribute('aria-label', teamNavLabel);
    const dancesNav = document.querySelector('[data-view="score"]');
    if (dancesNav) dancesNav.hidden = liveContext.leagueStatus !== 'active';
    const assignmentMap = new Map(data.assignments.map((assignment) => [assignment.cast_member_id, assignment.fantasy_team_id]));
    const memberByTeam = new Map(data.members.map((member) => [member.fantasy_team_id, member]));
    const score = scoreLeague(data, liveContext);
    activeWorkspaceDetail = { context: liveContext, data, score, assignmentMap, memberByTeam, predictions, refreshSignature };
    renderStandings(liveContext, data, score, assignmentMap, memberByTeam, refresh);
    renderMyTeam(liveContext, data, score, assignmentMap, memberByTeam, refresh);
    const refreshTrades = () => {
      if (activeWorkspaceDetail?.context.leagueId === liveContext.leagueId
        && !document.hidden && !$('#modal')?.open && $('#workspaceTradeCenter')) {
        renderWorkspaceTrades(liveContext, data, assignmentMap, memberByTeam, refresh);
      }
    };
    refreshCurrentWorkspaceTrades = liveContext.leagueStatus === 'active' ? refreshTrades : null;
    if (liveContext.leagueStatus === 'active') refreshTrades();
    if (liveContext.leagueStatus === 'active') renderDances(liveContext, data, score, assignmentMap, memberByTeam);
    else { $('#weekTabs').innerHTML = ''; $('#scoreDeskContent').innerHTML = ''; }
    await renderLeague(liveContext, data, assignmentMap, memberByTeam, score, refresh);
    if (version !== workspaceVersion) return;
    clearInterval(workspaceRefreshTimer);
    clearInterval(workspaceTradeRefreshTimer);
    refreshCurrentWorkspaceDraft = null;
    if (liveContext.leagueStatus === 'setup' || liveContext.leagueStatus === 'drafting') {
      const knownStatus = liveContext.leagueStatus;
      const knownPickCount = data.picks.length;
      const knownPaused = liveContext.draftPaused;
      const knownReadiness = data.readiness.map((item) => `${item.user_id}:${Boolean(item.ready_at)}`).sort().join('|');
      const pollDraft = async () => {
        if (document.hidden || workspaceDraftPollInFlight || version !== workspaceVersion) return;
        workspaceDraftPollInFlight = true;
        try {
          const { data: state, error } = await db.rpc('advance_league_draft_clock', { p_league_id: liveContext.leagueId });
          if (error) throw error;
          if (version !== workspaceVersion) return;
          const statePaused = state.status === 'drafting' && (Boolean(state.airing_locked)
            || !liveContext.draftTimerDisabled && !state.deadline_at);
          const readinessResult = knownStatus === 'setup' && state.status === 'setup'
            ? await db.rpc('get_league_draft_readiness', { p_league_id: liveContext.leagueId }) : null;
          if (readinessResult?.error) throw readinessResult.error;
          const weekStatusResult = knownStatus === 'setup' && liveContext.draftAiringLocked
            ? await db.from('weeks').select('id,is_complete') : null;
          if (weekStatusResult?.error) throw weekStatusResult.error;
          if (version !== workspaceVersion) return;
          const stateReadiness = readinessResult?.data?.map((item) => `${item.user_id}:${Boolean(item.ready_at)}`).sort().join('|') || knownReadiness;
          const weekStatusChanged = weekStatusResult?.data?.some((week) =>
            week.is_complete !== data.weeks.find((known) => known.id === week.id)?.is_complete) || false;
          if (state.status !== knownStatus || state.pick_count !== knownPickCount
            || statePaused !== knownPaused || (state.status === 'drafting'
              && Boolean(state.airing_locked) !== liveContext.draftAiringLocked)
            || stateReadiness !== knownReadiness || weekStatusChanged
            || isDraftAiringLocked(data.weeks) !== liveContext.draftAiringLocked) {
            if (state.pick_count !== knownPickCount) selectedDraftRound = null;
            await refresh();
          } else if (state.status === 'drafting' && !liveContext.draftTimerDisabled) updateDraftClock(state.deadline_at, state.server_now, statePaused);
        } catch (error) {
          console.warn('Draft update unavailable', error);
        } finally {
          workspaceDraftPollInFlight = false;
        }
      };
      refreshCurrentWorkspaceDraft = pollDraft;
      workspaceRefreshTimer = setInterval(pollDraft, 4000);
      if (liveContext.leagueStatus === 'drafting') pollDraft();
    } else {
      clearInterval(workspaceDraftTimer);
      workspaceDraftTimer = null;
      workspaceRefreshTimer = setInterval(() => {
        if (!document.hidden) renderSecondaryLeague(context, { silent: true, light: true });
      }, 30000);
    }
    if (liveContext.leagueStatus === 'active') {
      workspaceTradeRefreshTimer = setInterval(refreshTrades, 10000);
    }
  } catch (error) {
    if (version !== workspaceVersion) return;
    if (silent) {
      refreshCurrentWorkspaceTrades = previousTradesRefresh;
      console.warn('League refresh unavailable', error);
      return;
    }
    const message = `<div class="card pad"><b>Couldn’t load this league.</b><p class="sub">${safe(errorMessage(error))}</p><button class="retry-workspace">Try again</button></div>`;
    for (const id of ['#standingsContent', '#publicTeamResults', '#commissionerTeamResults', '#scoreDeskContent']) {
      const container = $(id);
      if (!container) continue;
      container.innerHTML = message;
      container.querySelector('.retry-workspace').addEventListener('click', refresh);
    }
  }
}

export function stopSecondaryLeague() {
  $('#workspaceReadOnlyBanner')?.remove();
  ++workspaceVersion;
  ++tradeRequestVersion;
  clearInterval(workspaceRefreshTimer);
  clearInterval(workspaceDraftTimer);
  clearInterval(workspaceTradeRefreshTimer);
  workspaceRefreshTimer = null;
  workspaceDraftTimer = null;
  workspaceTradeRefreshTimer = null;
  refreshCurrentWorkspaceDraft = null;
  refreshCurrentWorkspaceTrades = null;
  selectedDraftRound = null;
  selectedTeamWeekId = 'all';
  selectedWorkspaceOverviewTeamId = null;
  activeWorkspaceDetail = null;
  lastFullWorkspaceLoadAt = 0;
  lastSnapshotCheckAt = 0;
  lastSnapshotLeagueId = null;
  window.removeEventListener('resize', window.workspaceOverviewResize);
  window.workspaceOverviewResize = null;
}

window.addEventListener('dance-images-updated', () => {
  const state = activeWorkspaceDetail;
  if (state?.context.leagueStatus === 'active') {
    renderDances(state.context, state.data, state.score, state.assignmentMap, state.memberByTeam);
  }
});

window.addEventListener('focus', () => { refreshCurrentWorkspaceTrades?.(); refreshCurrentWorkspaceDraft?.(); });
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) { refreshCurrentWorkspaceTrades?.(); refreshCurrentWorkspaceDraft?.(); }
});
$('#modal')?.addEventListener('close', () => refreshCurrentWorkspaceTrades?.());
