import { db } from './supabase-client.js';

const $ = (selector) => document.querySelector(selector);
const safe = (value = '') => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const defaultLeagueId = '00000000-0000-4000-8000-000000000001';
let workspaceVersion = 0;
let workspaceRefreshTimer = null;
let workspaceTradeRefreshTimer = null;
let refreshCurrentWorkspaceTrades = null;
let tradeRequestVersion = 0;
let hubVersion = 0;
let workspaceActionPending = false;
let selectedDanceWeekId = null;
let tradeTab = 'active';
let workspaceRosterFilter = 'all';

function dialog(markup) {
  const modal = $('#modal');
  $('#modalBody').innerHTML = `<div class="modal">${markup}</div>`;
  modal.dataset.dirty = 'false';
  $('#modalClose').onclick = () => modal.close();
  modal.oncancel = null;
  if (!modal.open) modal.showModal();
}

function errorMessage(error, fallback = 'Please try again.') {
  console.error(error);
  return error?.message || fallback;
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

function castTile(member, action = '', tag = 'article') {
  return `<${tag} class="workspace-cast-tile"><img src="${safe(castImage(member))}" alt=""><span><b>${safe(member.name)}</b><small>${safe(member.role === 'DWTS Next Pro' ? 'Next Pro' : member.role)}</small></span>${action}</${tag}>`;
}

async function runAction(action, success, button = document.activeElement) {
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

export async function renderLeagueHub(context) {
  const version = ++hubVersion;
  const container = $('#leagueHubContent');
  const joinBanner = $('#joinInviteBanner');
  if (!container || !joinBanner) return;
  const leagues = context.leagues || [];
  const signedIn = context.signedIn;
  const membershipLimitReached = leagues.length >= 5;
  let invites = [];
  if (signedIn) {
    const result = await db.rpc('get_my_league_invites');
    if (version !== hubVersion) return;
    if (!result.error) invites = result.data || [];
    else console.error(result.error);
  }

  const token = context.joinToken;
  if (token) {
    const preview = await db.rpc('preview_league_invite_link', { p_token: token });
    if (version !== hubVersion) return;
    const league = preview.data?.[0];
    joinBanner.innerHTML = league
      ? `<div class="card pad workspace-invite-banner"><p class="eyebrow">League invitation</p><h2>Join ${safe(league.league_name)}</h2><p class="sub">${signedIn ? membershipLimitReached ? 'You already belong to the maximum of five leagues.' : context.onboardingCompleted ? 'You can join this league now.' : 'We’ll save your profile before joining.' : 'Continue with Google or Apple to join.'}</p><button id="joinSharedLeague" ${signedIn && !membershipLimitReached && !context.leaguesError ? '' : 'disabled'}>Join league</button>${signedIn ? '' : '<a href="#signin" id="joinSignInLink">Sign in</a>'}</div>`
      : '<div class="card pad">This invitation link has expired or was revoked.</div>';
    $('#joinSharedLeague')?.addEventListener('click', () => runAction(
      async () => {
        const profile = await completeProfileIfNeeded(context);
        return profile.error ? profile : db.rpc('join_league_with_link', { p_token: token });
      },
      async () => { const id = league.league_id; location.assign(leagueUrl(id)); },
      $('#joinSharedLeague'),
    ));
    $('#joinSignInLink')?.addEventListener('click', (event) => {
      event.preventDefault();
      $('#auth')?.click();
    });
  } else joinBanner.innerHTML = '';

  if (!signedIn) {
    container.innerHTML = '';
    return;
  }
  const ownedCount = leagues.filter((league) => league.member_role === 'owner' && league.league_id !== defaultLeagueId).length;
  const createDisabled = context.leaguesError || membershipLimitReached || ownedCount >= 2;
  const onboarding = !context.onboardingCompleted
    ? '<p class="account-league-note">Your profile details will be saved when you join or create a league.</p>' : '';
  container.innerHTML = `${onboarding}<div class="workspace-section-head"><h2>Your leagues</h2><button id="createLeagueButton" type="button" ${createDisabled ? 'disabled' : ''}>Create</button></div>${context.leaguesError ? '<p class="account-league-note">Couldn’t load your leagues. Refresh to try again.</p><button id="retryAccountLeagues" type="button">Try again</button>' : `<div class="workspace-league-list">${leagues.map((league) => `<a class="workspace-league-link ${league.league_id === context.leagueId ? 'current' : ''}" href="${safe(leagueUrl(league.league_id))}" ${league.league_id === context.leagueId ? 'aria-current="page"' : ''}><span><b>${safe(league.name)}</b><small>${league.status === 'setup' ? 'Setting up' : league.status === 'drafting' ? 'Draft in progress' : 'Season in progress'} · ${safe(league.member_role)}</small></span><span aria-hidden="true">›</span></a>`).join('') || '<p class="account-league-note">No leagues yet. Create one to invite friends.</p>'}</div><p class="account-league-limits">${leagues.length} of 5 joined · ${ownedCount} of 2 created</p>`}${invites.length ? `<section class="workspace-invites-mini"><div class="workspace-inbox-head"><h2>Invitations</h2><span>${invites.length}</span></div><div class="workspace-invite-list">${invites.map((invite) => `<article class="workspace-invite-row"><span class="workspace-invite-mark" aria-hidden="true">${safe(invite.league_name.charAt(0).toUpperCase())}</span><div class="workspace-invite-copy"><b>${safe(invite.league_name)}</b><small>Invited by @${safe(invite.inviter_username)}</small></div><div class="workspace-invite-actions"><button data-invite-accept="${invite.id}" ${membershipLimitReached || context.leaguesError ? 'disabled' : ''}>Join</button><button class="secondary" data-invite-decline="${invite.id}">Decline</button></div></article>`).join('')}</div></section>` : ''}`;
  $('#retryAccountLeagues')?.addEventListener('click', () => location.reload());
  $('#createLeagueButton')?.addEventListener('click', () => {
    dialog('<p class="eyebrow">New league</p><h2>Create a League</h2><p class="sub">Name your league, then invite 2–5 more managers. Roster size adjusts automatically as they join; you can change it in League settings before the draft.</p><label>League name<input id="newLeagueName" maxlength="80" placeholder="e.g. Saturday Night League"></label><div class="modal-actions"><button id="confirmCreateLeague">Create league</button></div>');
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
  container.querySelectorAll('[data-invite-accept], [data-invite-decline]').forEach((button) => {
    button.addEventListener('click', () => runAction(
      async () => {
        if (button.dataset.inviteAccept) {
          const profile = await completeProfileIfNeeded(context);
          if (profile.error) return profile;
        }
        return db.rpc('respond_to_league_invite', {
          p_invite_id: button.dataset.inviteAccept || button.dataset.inviteDecline,
          p_accept: Boolean(button.dataset.inviteAccept),
        });
      },
      async () => { location.reload(); },
      button,
    ));
  });
}

function draftTurn(order, picks, rosterSize) {
  if (!order.length || picks.length >= order.length * rosterSize) return null;
  const round = Math.floor(picks.length / order.length) + 1;
  const slot = picks.length % order.length;
  return { round, teamId: order[round % 2 ? slot : order.length - slot - 1].fantasy_team_id,
    pickNumber: picks.length + 1 };
}

function scoreLeague(data, context) {
  const teams = data.teams;
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const pairById = new Map(data.pairs.map((pair) => [pair.id, pair]));
  const weekById = new Map(data.weeks.map((week) => [week.id, week]));
  const danceById = new Map(data.dances.map((dance) => [dance.id, dance]));
  const scoreByDance = new Map();
  const rateByName = new Map(data.roles.map((role) => {
    const leagueRate = data.rates.find((rate) => rate.role_id === role.id);
    return [role.name, Number(leagueRate?.appearance_points ?? role.appearance_points) || 0];
  }));
  const snapshotByKey = new Map(data.snapshots.map((snapshot) => [`${snapshot.week_id}:${snapshot.cast_member_id}`, snapshot]));
  const totalByTeam = new Map(teams.map((team) => [team.id, 0]));
  const pointsByTeamCast = new Map(teams.map((team) => [team.id, new Map()]));
  const pointsByWeekTeam = new Map();
  const scoringWeeks = context.leagueStatus === 'active'
    ? data.weeks.filter((week) => week.is_complete && week.number > context.scoringStartsAfterWeek)
    : [];
  if (scoringWeeks.some((week) => !data.snapshots.some((snapshot) => snapshot.week_id === week.id))) {
    throw new Error('A completed week is missing this league’s roster snapshot. Scoring is paused until it is repaired.');
  }
  data.scores.forEach((score) => scoreByDance.set(score.dance_id, (scoreByDance.get(score.dance_id) || 0) + Number(score.score || 0)));
  const add = (castId, weekId, amount) => {
    const week = weekById.get(weekId);
    if (context.leagueStatus !== 'active' || !week || !week.is_complete || week.number <= context.scoringStartsAfterWeek) return;
    const teamId = snapshotByKey.get(`${weekId}:${castId}`)?.fantasy_team_id;
    if (!teamId || !totalByTeam.has(teamId)) return;
    totalByTeam.set(teamId, totalByTeam.get(teamId) + amount);
    const castPoints = pointsByTeamCast.get(teamId);
    castPoints.set(castId, (castPoints.get(castId) || 0) + amount);
    const key = `${weekId}:${teamId}`;
    pointsByWeekTeam.set(key, (pointsByWeekTeam.get(key) || 0) + amount);
  };
  data.dances.filter((dance) => dance.kind === 'competitive').forEach((dance) => {
    const pair = pairById.get(dance.partnership_id);
    if (!pair) return;
    const score = scoreByDance.get(dance.id) || 0;
    add(pair.star_id, dance.week_id, score);
    add(pair.pro_id, dance.week_id, score);
  });
  data.appearances.forEach((appearance) => {
    const dance = danceById.get(appearance.dance_id);
    if (!dance) return;
    const cast = castById.get(appearance.cast_member_id);
    if (!cast) return;
    const snapshot = snapshotByKey.get(`${dance.week_id}:${cast.id}`);
    const role = snapshot?.cast_role || cast.role;
    const rate = snapshot?.appearance_points != null ? Number(snapshot.appearance_points)
      : cast.is_hough ? rateByName.get('Hough') || 0
        : role === 'Surprise' ? Number(cast.custom_appearance_points) || 0
          : rateByName.get(role) || 0;
    add(cast.id, dance.week_id, rate);
  });
  return { totalByTeam, pointsByTeamCast, pointsByWeekTeam, scoringWeeks, rateByName, scoreByDance, snapshotByKey };
}

async function loadWorkspaceData(context) {
  const leagueId = context.leagueId;
  const queries = {
    league: db.from('leagues').select('id,name,status,roster_size,roster_size_overridden,scoring_starts_after_week').eq('id', leagueId).single(),
    teams: db.from('fantasy_teams').select('id,league_id,manager_name,team_name').eq('league_id', leagueId),
    assignments: db.from('league_roster_assignments').select('cast_member_id,fantasy_team_id').eq('league_id', leagueId),
    cast: db.from('cast_members').select('*').order('name'),
    members: db.rpc('list_league_members', { p_league_id: leagueId }),
    roles: db.from('roles').select('id,name,appearance_points'),
    rates: db.from('league_role_rates').select('role_id,appearance_points').eq('league_id', leagueId),
    weeks: db.from('weeks').select('id,number,title,theme,is_complete,air_date').order('number'),
    pairs: db.from('partnerships').select('id,star_id,pro_id'),
    dances: db.from('dances').select('id,week_id,kind,partnership_id,name,dance_type,song,sort_order').order('sort_order'),
    scores: db.from('dance_judge_scores').select('dance_id,judge_name,score'),
    appearances: db.from('dance_appearances').select('dance_id,cast_member_id'),
    snapshots: db.from('league_weekly_roster_snapshots').select('*').eq('league_id', leagueId),
    order: db.from('league_draft_order').select('draft_position,fantasy_team_id').eq('league_id', leagueId).order('draft_position'),
    picks: db.from('league_draft_picks').select('pick_number,round_number,fantasy_team_id,cast_member_id,picked_at').eq('league_id', leagueId).order('pick_number'),
  };
  const results = await Promise.all(Object.values(queries));
  const failure = results.find((result) => result.error)?.error;
  if (failure) throw failure;
  return Object.fromEntries(Object.keys(queries).map((key, index) => [key, results[index].data || []]));
}

function renderStandings(context, data, score, assignmentMap, memberByTeam, refresh) {
  const rows = [...data.teams].map((team) => ({ ...team, points: score.totalByTeam.get(team.id) || 0,
    manager: memberByTeam.get(team.id)?.display_name || team.manager_name })).sort((a, b) => b.points - a.points || (a.team_name || a.manager).localeCompare(b.team_name || b.manager));
  const isSetup = context.leagueStatus === 'setup';
  const isDrafting = context.leagueStatus === 'drafting';
  $('#standings .eyebrow').textContent = context.leagueName;
  $('#standingsSubtitle').textContent = isSetup
    ? 'Your league is getting ready for its draft.'
    : context.leagueStatus === 'drafting' ? 'The draft is underway. Standings begin after every roster is filled.'
      : score.scoringWeeks.length ? 'Scores from every completed show count toward this league.' : 'The season is ready. Scores will appear after the first completed show.';
  const turn = draftTurn(data.order, data.picks, context.rosterSize);
  const setupPanel = isSetup ? `<section class="card pad workspace-setup-panel"><p class="eyebrow">Before the draft</p><h2>Build your league</h2><p class="sub">${data.members.length} of 3–6 managers joined. ${data.members.length < 3 ? `Invite ${3 - data.members.length} more to start.` : 'Your league can start its draft whenever the owner is ready.'} Roster size is currently ${context.rosterSize} cast per team${context.rosterSizeOverridden ? ' (custom)' : ' (automatic)'}.</p><div class="workspace-setup-facts"><span><b>${data.members.length}</b> managers</span><span><b>${context.rosterSize}</b> draft rounds</span><span><b>${data.cast.length}</b> cast in pool</span></div>${context.leagueRole === 'owner' ? `<div class="modal-actions">${data.members.length < 6 ? '<button id="overviewInvitePlayers">Invite players</button>' : ''}<button id="overviewLeagueSettings" class="secondary">League settings</button></div>` : '<p class="sub">The league owner can invite managers and start the draft when at least three have joined.</p>'}</section>` : isDrafting ? `<section class="card pad workspace-setup-panel"><p class="eyebrow">Draft in progress</p><h2>Round ${turn?.round || context.rosterSize} of ${context.rosterSize}</h2><p class="sub">${data.picks.length} of ${data.order.length * context.rosterSize} picks complete. ${turn ? `${safe(memberByTeam.get(turn.teamId)?.display_name || 'The next manager')} is on the clock.` : 'Every roster is filled.'}</p><a class="workspace-inline-link" href="#teams" id="overviewOpenDraft">View the draft</a></section>` : !score.scoringWeeks.length ? '<section class="card pad workspace-setup-panel"><p class="eyebrow">Season ready</p><h2>Waiting for the first completed show</h2><p class="sub">Your draft teams are set. Weekly points and highlights will appear after a show is completed.</p></section>' : '';
  $('#standingsContent').innerHTML = `${setupPanel}${rows.length ? `<div class="workspace-standings-list">${rows.map((team, index) => `<button type="button" class="card workspace-standing-card" data-workspace-standing="${team.id}" aria-label="View ${safe(team.team_name || team.manager)} roster"><span class="workspace-rank">${isSetup || isDrafting ? '•' : index + 1}</span><span><small>${safe(team.manager)}</small><b>${safe(team.team_name || `${team.manager.split(' ')[0]}'s Team`)}</b></span><strong>${context.leagueStatus === 'active' ? `${team.points} pts` : `${[...assignmentMap.values()].filter((id) => id === team.id).length}/${context.rosterSize} cast`}</strong></button>`).join('')}</div>` : '<div class="card pad">No teams yet.</div>'}`;
  $('#overviewInvitePlayers')?.remove();
  $('#overviewLeagueSettings')?.addEventListener('click', () => openLeagueSettings(context, refresh));
  $('#overviewOpenDraft')?.addEventListener('click', (event) => { event.preventDefault(); $('#myTeamNav').click(); });
  $('#standingsContent').querySelectorAll('[data-workspace-standing]').forEach((button) => button.addEventListener('click', () => {
    const team = rows.find((item) => item.id === button.dataset.workspaceStanding);
    const roster = data.cast.filter((cast) => assignmentMap.get(cast.id) === team.id)
      .sort((a, b) => (score.pointsByTeamCast.get(team.id)?.get(b.id) || 0)
        - (score.pointsByTeamCast.get(team.id)?.get(a.id) || 0));
    dialog(`<p class="eyebrow">${safe(context.leagueName)}</p><h2>${safe(team.team_name || `${team.manager.split(' ')[0]}'s Team`)}</h2><p class="sub">Managed by ${safe(team.manager)} · ${context.leagueStatus === 'active' ? `${team.points} season points` : `${roster.length}/${context.rosterSize} cast drafted`}</p><div class="workspace-cast-list">${roster.map((cast) => castTile(cast, context.leagueStatus === 'active' ? `<strong class="workspace-points">${score.pointsByTeamCast.get(team.id)?.get(cast.id) || 0} pts</strong>` : '')).join('') || '<p class="sub">The draft has not filled this roster yet.</p>'}</div>`);
  }));
  $('#overviewTeamDetail').innerHTML = '';
  $('.highlight-preview').hidden = true;
  $('.highlight-preview').style.display = 'none';
}

function renderMyTeam(context, data, score, assignmentMap, memberByTeam, refresh) {
  const ownTeam = data.teams.find((team) => team.id === context.fantasyTeamId);
  const body = $('#publicTeamResults');
  if (!ownTeam) { body.innerHTML = '<div class="card pad">Your team has not been connected yet.</div>'; return; }
  const roster = data.cast.filter((member) => assignmentMap.get(member.id) === ownTeam.id);
  const available = data.cast.filter((member) => !assignmentMap.has(member.id));
  const turn = draftTurn(data.order, data.picks, context.rosterSize);
  const isYourTurn = context.leagueStatus === 'drafting' && turn?.teamId === ownTeam.id;
  $('#myTeamTitle').textContent = context.leagueStatus === 'active' ? ownTeam.team_name || 'My Team' : 'Draft';
  $('#myTeamEyebrow').textContent = `${context.displayName || 'Your'} · ${context.leagueName}`;
  $('#myTeamSubtitle').textContent = context.leagueStatus === 'setup'
    ? 'Invitations and league settings are open. The draft begins when 3–6 managers have joined.'
    : context.leagueStatus === 'drafting' ? 'Follow the draft order and claim cast members when it is your turn.'
      : 'View your roster, weekly scores, and the available cast.';
  const draftStrip = context.leagueStatus === 'setup'
    ? `<div class="workspace-draft-strip"><div><small>Draft setup</small><strong>${data.members.length} of 3–6 managers joined</strong><p class="sub">${context.rosterSize} rounds · ${context.rosterSizeOverridden ? 'custom' : 'automatic'} roster size</p></div>${context.leagueRole === 'owner' ? `<button id="startDraftFromTeam" ${data.members.length >= 3 && data.members.length <= 6 ? '' : 'disabled'}>Start draft</button>` : ''}</div>`
    : context.leagueStatus === 'drafting'
      ? `<div class="workspace-draft-strip"><div><small>Draft order · Round ${turn?.round || context.rosterSize}</small><div class="workspace-draft-order">${data.order.map((slot) => `<span class="${turn?.teamId === slot.fantasy_team_id ? 'current' : ''}">${slot.draft_position}. ${safe(memberByTeam.get(slot.fantasy_team_id)?.display_name || 'Manager')}</span>`).join('')}</div></div><strong>${isYourTurn ? 'Your pick' : `Pick ${turn?.pickNumber || '—'}`}</strong></div>`
      : `<div class="workspace-draft-strip"><div><small>Season points</small><strong>${score.totalByTeam.get(ownTeam.id) || 0}</strong></div><div class="workspace-week-pills">${score.scoringWeeks.map((week) => `<span>Week ${week.number} · ${score.pointsByWeekTeam.get(`${week.id}:${ownTeam.id}`) || 0}</span>`).join('')}</div></div>`;
  const canClaim = isYourTurn || context.leagueStatus === 'active';
  body.innerHTML = `<section class="card public-team-detail workspace-team-detail">${draftStrip}<div class="public-team-columns"><section><div class="public-section-head"><div><p class="eyebrow">${context.leagueStatus === 'drafting' ? `Round ${turn?.round || 1} of ${context.rosterSize}` : 'Roster'}</p><h3>Team Roster · ${roster.length}/${context.rosterSize}</h3></div></div><div class="workspace-cast-list">${roster.map((member) => castTile(member, context.leagueStatus === 'active' ? `<strong class="workspace-points">${score.pointsByTeamCast.get(ownTeam.id)?.get(member.id) || 0} pts</strong>` : '')).join('') || '<p class="sub">Your picks will appear here.</p>'}</div></section><div class="team-side-column"><section class="available-cast-panel"><div class="public-section-head"><div><p class="eyebrow">${context.leagueStatus === 'drafting' ? 'Draft pool' : 'Free agents'}</p><h3>Available Cast</h3></div><span>${available.length} available</span></div><p class="sub">${isYourTurn ? 'It is your turn. Claim one cast member below.' : context.leagueStatus === 'drafting' ? 'Claims open when it is your turn.' : context.leagueStatus === 'active' ? 'Claim a cast member by releasing one from your roster.' : 'Claims open after the draft starts.'}</p><div class="workspace-available-list">${available.map((member) => castTile(member, canClaim ? `<button data-workspace-claim="${member.id}">Claim</button>` : '')).join('') || '<p class="sub">No cast members are available.</p>'}</div></section>${context.leagueStatus === 'active' ? '<section id="workspaceTradeCenter" class="card pad workspace-trades">Loading trades…</section>' : `<section class="card pad workspace-draft-history"><p class="eyebrow">Draft</p><h3>Recent picks</h3>${data.picks.slice(-6).reverse().map((pick) => `<p><b>#${pick.pick_number}</b> ${safe(data.cast.find((member) => member.id === pick.cast_member_id)?.name || 'Cast member')} · ${safe(memberByTeam.get(pick.fantasy_team_id)?.display_name || 'Manager')}</p>`).join('') || '<p class="sub">No picks yet.</p>'}</section>`}</div></div></section>`;
  $('#startDraftFromTeam')?.addEventListener('click', () => confirmStartDraft(context));
  $('#editMyTeam').hidden = false;
  $('#editMyTeam').onclick = () => {
    dialog(`<p class="eyebrow">Team settings</p><h2>Edit team name</h2><label>Team name<input id="workspaceTeamName" maxlength="80" value="${safe(ownTeam.team_name || '')}"></label><div class="modal-actions"><button id="saveWorkspaceTeamName">Save</button></div>`);
    $('#saveWorkspaceTeamName').addEventListener('click', () => runAction(
      () => db.rpc('update_league_team_name', { p_league_id: context.leagueId, p_team_name: $('#workspaceTeamName').value.trim() }),
      async () => { $('#modal').close(); await refresh(); },
      $('#saveWorkspaceTeamName'),
    ));
  };
  body.querySelectorAll('[data-workspace-claim]').forEach((button) => button.addEventListener('click', () => {
    const incoming = data.cast.find((member) => member.id === button.dataset.workspaceClaim);
    if (!incoming) return;
    if (context.leagueStatus === 'drafting') {
      dialog(`<p class="eyebrow">Draft pick #${turn.pickNumber}</p><h2>Claim ${safe(incoming.name)}?</h2>${castTile(incoming)}<p class="sub">This pick is final and will fill one of your ${context.rosterSize} roster spots.</p><div class="modal-actions"><button id="confirmWorkspaceClaim">Claim cast member</button></div>`);
      $('#confirmWorkspaceClaim').addEventListener('click', () => runAction(
        () => db.rpc('claim_league_cast_member', { p_league_id: context.leagueId, p_incoming_cast_member_id: incoming.id }),
        async () => { $('#modal').close(); location.reload(); },
        $('#confirmWorkspaceClaim'),
      ));
    } else {
      dialog(`<p class="eyebrow">Free-agent claim</p><h2>Claim ${safe(incoming.name)}</h2><p class="sub">Choose one cast member from your roster to release.</p>${castTile(incoming)}<div class="workspace-release-list">${roster.map((member) => `<button class="workspace-release-choice" data-workspace-release="${member.id}">${safe(member.name)}</button>`).join('')}</div><div class="modal-actions"><button id="confirmWorkspaceClaim" disabled>Swap cast</button></div>`);
      let outgoingId = null;
      $('#modalBody').querySelectorAll('[data-workspace-release]').forEach((choice) => choice.addEventListener('click', () => {
        outgoingId = choice.dataset.workspaceRelease;
        $('#modalBody').querySelectorAll('[data-workspace-release]').forEach((item) => item.classList.toggle('selected', item === choice));
        $('#confirmWorkspaceClaim').disabled = false;
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
  const teamName = (id) => memberByTeam.get(id)?.team_name || memberByTeam.get(id)?.display_name || 'Team';
  const castName = (id) => castById.get(id)?.name || 'Cast member';
  const ownId = context.fantasyTeamId;
  const offerCard = (offer) => {
    const mineId = offer.initiator_team_id === ownId ? offer.initiator_cast_member_id : offer.counterparty_cast_member_id;
    const theirsId = offer.initiator_team_id === ownId ? offer.counterparty_cast_member_id : offer.initiator_cast_member_id;
    const theirTeamId = offer.initiator_team_id === ownId ? offer.counterparty_team_id : offer.initiator_team_id;
    const waitingForMe = offer.awaiting_team_id === ownId;
    const hoursLeft = Math.max(0, Math.ceil((new Date(offer.expires_at).getTime() - Date.now()) / 3600000));
    return `<article class="workspace-trade-card"><small>${offer.status === 'countered' ? 'Counter offer' : 'Trade offer'} · ${waitingForMe ? 'Your response' : `Waiting for ${safe(teamName(theirTeamId))}`} · ${hoursLeft}h left</small><div class="workspace-trade-swap">${castTile(castById.get(mineId) || { name: castName(mineId), role: '' })}<span>⇄</span>${castTile(castById.get(theirsId) || { name: castName(theirsId), role: '' })}</div><div class="workspace-trade-actions">${waitingForMe ? `<button data-workspace-trade="accept:${offer.id}">Accept</button><button class="secondary" data-workspace-trade="counter:${offer.id}">Counter</button><button class="secondary" data-workspace-trade="deny:${offer.id}">Deny</button>` : `<button class="secondary" data-workspace-trade="cancel:${offer.id}">Cancel</button>`}</div></article>`;
  };
  const eventCard = (event, notification = false) => `<article class="workspace-trade-card"><small>${safe(event.event_type)} · ${new Date(event.event_at).toLocaleDateString()}</small><b>${safe(event.initiator_cast_member_name)} ⇄ ${safe(event.counterparty_cast_member_name)}</b>${notification ? `<button class="secondary" data-dismiss-workspace-trade="${event.id}">Dismiss</button>` : ''}</article>`;
  center.innerHTML = `<div class="workspace-section-head"><div><p class="eyebrow">Manager tools</p><h3>Trades</h3></div><button id="proposeWorkspaceTrade">Propose trade</button></div><div class="workspace-trade-tabs"><button data-workspace-trade-tab="active" class="${tradeTab === 'active' ? 'selected' : ''}">Active ${(trades.offers?.length || 0) + (trades.notifications?.length || 0)}</button><button data-workspace-trade-tab="history" class="${tradeTab === 'history' ? 'selected' : ''}">History</button></div>${tradeTab === 'active' ? `${(trades.notifications || []).map((item) => eventCard(item, true)).join('')}${(trades.offers || []).map(offerCard).join('') || (trades.notifications?.length ? '' : '<p class="sub">No active trades.</p>')}` : `${(trades.history || []).map((item) => eventCard(item)).join('') || '<p class="sub">No past trades.</p>'}`}`;
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

function openWorkspaceTradeBuilder(context, data, assignmentMap, memberByTeam, refresh) {
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const own = data.cast.filter((member) => assignmentMap.get(member.id) === context.fantasyTeamId);
  const others = data.teams.filter((team) => team.id !== context.fantasyTeamId);
  const state = { mine: null, team: null, theirs: null };
  const render = () => {
    const theirs = state.team ? data.cast.filter((member) => assignmentMap.get(member.id) === state.team) : [];
    dialog(`<p class="eyebrow">New trade</p><h2>Propose a Trade</h2><p class="sub">Choose one of your cast members, another team, and the cast member you want. The other manager has 48 hours.</p><h3>You send</h3><div class="workspace-trade-picker">${own.map((member) => `<button class="${state.mine === member.id ? 'selected' : ''}" data-builder-mine="${member.id}">${castTile(member, '', 'span')}</button>`).join('')}</div><h3>Trade with</h3><div class="workspace-trade-team-picker">${others.map((team) => `<button class="${state.team === team.id ? 'selected' : ''}" data-builder-team="${team.id}">${safe(team.team_name || memberByTeam.get(team.id)?.display_name || 'Team')}</button>`).join('')}</div>${state.team ? `<h3>You receive</h3><div class="workspace-trade-picker">${theirs.map((member) => `<button class="${state.theirs === member.id ? 'selected' : ''}" data-builder-theirs="${member.id}">${castTile(member, '', 'span')}</button>`).join('')}</div>` : ''}<div class="modal-actions"><button id="sendWorkspaceTrade" ${state.mine && state.theirs ? '' : 'disabled'}>Send Trade</button></div>`);
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
    dialog(`<p class="eyebrow">Trade response</p><h2>Counter Offer</h2><p class="sub">Select the cast member to replace. Change one side only.</p><div class="workspace-counter-swap">${sideCard('initiator', offer.initiator_cast_member_id)}<span>⇄</span>${sideCard('counterparty', offer.counterparty_cast_member_id)}</div>${state.replacement ? '<button id="clearWorkspaceCounter" class="secondary">× Remove change</button>' : ''}${state.side && !state.replacement ? `<h3>Choose a replacement</h3><div class="workspace-trade-picker">${options.map((member) => `<button data-counter-replacement="${member.id}">${castTile(member, '', 'span')}</button>`).join('')}</div>` : ''}<div class="modal-actions"><button id="sendWorkspaceCounter" ${state.replacement ? '' : 'disabled'}>Send counter</button></div>`);
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
  const teamFor = (castId) => {
    if (week.is_complete) {
      const snapshot = score.snapshotByKey.get(`${week.id}:${castId}`);
      if (!snapshot) return 'Historical roster unavailable';
      if (!snapshot.fantasy_team_id) return 'Available cast';
      return snapshot.team_name || snapshot.manager_name || 'Historical team';
    }
    const teamId = assignmentMap.get(castId);
    return memberByTeam.get(teamId)?.team_name || memberByTeam.get(teamId)?.display_name || 'Available cast';
  };
  content.innerHTML = `<div class="card pad workspace-week-head"><p class="eyebrow">Week ${week.number}</p><h2>${safe(week.title || week.theme || `Week ${week.number}`)}</h2><p class="sub">${week.is_complete ? 'Completed show' : 'Upcoming show · scores pending'}</p></div><div class="workspace-dance-list">${weekDances.map((dance) => {
    const pair = pairById.get(dance.partnership_id);
    const names = pair ? `${nameFor(pair.star_id)} & ${nameFor(pair.pro_id)}` : dance.name || 'Performance';
    const total = score.scoreByDance.get(dance.id);
    return `<button type="button" class="card workspace-dance-card" data-workspace-dance="${dance.id}"><span><small>${safe(dance.kind)}${dance.dance_type ? ` · ${safe(dance.dance_type)}` : ''}</small><b>${safe(names)}</b><small>${safe(dance.song || '')}</small></span><strong>${week.is_complete && total != null ? total : 'View'}</strong></button>`;
  }).join('') || '<div class="card pad">No dances recorded for this week.</div>'}</div>`;
  content.querySelectorAll('[data-workspace-dance]').forEach((button) => button.addEventListener('click', () => {
    const dance = weekDances.find((item) => item.id === button.dataset.workspaceDance);
    const pair = pairById.get(dance.partnership_id);
    const involved = pair ? [pair.star_id, pair.pro_id] : data.appearances.filter((item) => item.dance_id === dance.id).map((item) => item.cast_member_id);
    const judges = data.scores.filter((item) => item.dance_id === dance.id);
    dialog(`<p class="eyebrow">Week ${week.number} · ${safe(dance.dance_type || dance.kind)}</p><h2>${safe(pair ? `${nameFor(pair.star_id)} & ${nameFor(pair.pro_id)}` : dance.name || 'Performance')}</h2><p class="sub">${safe(dance.song || 'Song not set')}</p><div class="workspace-dance-judges">${judges.map((judge) => `<span>${safe(judge.judge_name)} <b>${judge.score}</b></span>`).join('') || '<p>Scores pending.</p>'}</div><h3>Cast and fantasy teams</h3>${involved.map((id) => `<p>${safe(nameFor(id))} · ${safe(teamFor(id))}</p>`).join('')}${data.appearances.filter((item) => item.dance_id === dance.id && !involved.includes(item.cast_member_id)).map((item) => `<p>${safe(nameFor(item.cast_member_id))} · ${safe(teamFor(item.cast_member_id))}</p>`).join('')}`);
  }));
}

async function renderLeague(context, data, assignmentMap, memberByTeam, score, refresh) {
  const renderVersion = workspaceVersion;
  $('#leagueName').textContent = context.leagueName;
  $('#leagueTeamCount').textContent = data.teams.length;
  $('#leagueCastCount').textContent = data.cast.length;
  $('#leagueAvailableCount').textContent = data.cast.length - assignmentMap.size;
  $('#editLeagueName').hidden = context.leagueRole !== 'owner';
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
  $('#commissionerTeamResults').innerHTML = data.teams.map((team) => {
    const member = memberByTeam.get(team.id);
    const roster = data.cast.filter((cast) => assignmentMap.get(cast.id) === team.id);
    return `<article class="card pad workspace-league-team"><p class="eyebrow">${safe(member?.display_name || team.manager_name)}</p><h3>${safe(team.team_name || `${(member?.display_name || team.manager_name).split(' ')[0]}'s Team`)}</h3><small>${roster.length}/${context.rosterSize} cast · ${score.totalByTeam.get(team.id) || 0} points</small><div>${roster.map((cast) => `<span>${safe(cast.name)}</span>`).join('') || '<span>Draft not started</span>'}</div>${context.leagueRole === 'owner' && context.leagueStatus === 'setup' && member?.member_role === 'member' ? `<button class="secondary workspace-remove-manager" data-remove-member="${member.user_id}">Remove manager</button>` : ''}</article>`;
  }).join('');
  $('#rosterSearch').value = '';
  const rosterResults = $('#rosterResults');
  const drawCast = () => {
    const term = $('#rosterSearch').value.trim().toLowerCase();
    const matchesFilter = (cast) => workspaceRosterFilter === 'all'
      || (workspaceRosterFilter === 'pros' && ['Pro', 'Eliminated Pro', 'DWTS Next Pro'].includes(cast.role))
      || (workspaceRosterFilter === 'stars' && ['Star', 'Eliminated Star'].includes(cast.role))
      || (workspaceRosterFilter === 'bonus' && !['Pro', 'Eliminated Pro', 'DWTS Next Pro', 'Star', 'Eliminated Star'].includes(cast.role));
    rosterResults.innerHTML = data.cast.filter((cast) => cast.name.toLowerCase().includes(term) && matchesFilter(cast)).map((cast) =>
      `<button type="button" class="workspace-roster-row" data-workspace-cast="${cast.id}"><img src="${safe(castImage(cast))}" alt=""><span><b>${safe(cast.name)}</b><small>${safe(cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role)} · ${safe(memberByTeam.get(assignmentMap.get(cast.id))?.team_name || 'Available')}</small></span><span aria-hidden="true">›</span></button>`).join('') || '<p class="sub">No matching cast members.</p>';
    rosterResults.querySelectorAll('[data-workspace-cast]').forEach((button) => button.addEventListener('click', () => {
      const cast = data.cast.find((item) => item.id === button.dataset.workspaceCast);
      dialog(`<div class="workspace-profile-modal"><img src="${safe(castImage(cast))}" alt=""><div><p class="eyebrow">${safe(cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role)}</p><h2>${safe(cast.name)}</h2><p class="sub">${safe(memberByTeam.get(assignmentMap.get(cast.id))?.team_name || 'Available cast')}</p>${cast.bio ? `<p>${safe(cast.bio)}</p>` : ''}${cast.career_highlights ? `<p><b>Career highlights</b><br>${safe(cast.career_highlights)}</p>` : ''}${cast.mirrorball_wins ? `<p><b>Past Mirrorball wins:</b> ${cast.mirrorball_wins}</p>` : ''}</div></div>`);
    }));
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
  $('#roleRatesContent').innerHTML = `<div class="role-rate-grid">${data.rates.map((rate) => `<div class="card role-rate-item"><span>${safe(rateByRole.get(rate.role_id)?.name || 'Role')}</span><strong>${rate.appearance_points == null ? 'Varies' : `+${rate.appearance_points}`}</strong></div>`).join('')}</div>`;
  $('#editRules').hidden = context.leagueRole !== 'owner';
  $('#editRules').onclick = () => {
    dialog(`<h2>Appearance rates</h2><p class="sub">These rates belong only to ${safe(context.leagueName)}.</p>${data.rates.filter((rate) => rate.appearance_points != null).map((rate) => `<label>${safe(rateByRole.get(rate.role_id)?.name || 'Role')}<input type="number" min="0" max="99" data-workspace-rate="${safe(rateByRole.get(rate.role_id)?.name || '')}" value="${rate.appearance_points}"></label>`).join('')}<button id="saveWorkspaceRates">Save rates</button>`);
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
  dialog(`<h2>Start the draft?</h2><p class="sub">The order will be randomized once. ${context.memberCount} managers will each draft ${context.rosterSize} cast members in snake order. New members cannot join after it starts.</p><button id="confirmStartDraft">Start draft</button>`);
  $('#confirmStartDraft').addEventListener('click', () => runAction(
    () => db.rpc('start_league_draft', { p_league_id: context.leagueId }),
    async () => { $('#modal').close(); location.reload(); },
    $('#confirmStartDraft'),
  ));
}

function openLeagueSettings(context, refresh) {
  dialog(`<p class="eyebrow">League settings</p><h2>Edit ${safe(context.leagueName)}</h2><label>League name<input id="workspaceLeagueName" maxlength="80" value="${safe(context.leagueName)}"></label><label class="workspace-auto-size"><input id="workspaceAutoRoster" type="checkbox" ${context.rosterSizeOverridden ? '' : 'checked'} ${context.leagueStatus === 'setup' ? '' : 'disabled'}> Set roster size automatically as managers join</label><label>Cast members per team / draft rounds<input id="workspaceRosterSize" type="number" min="1" max="30" value="${context.rosterSize}" ${context.leagueStatus === 'setup' && context.rosterSizeOverridden ? '' : 'disabled'}></label><p class="sub">${context.leagueStatus === 'setup' ? `Current plan: ${context.memberCount} manager${context.memberCount === 1 ? '' : 's'} · ${context.rosterSize} rounds. Manual roster size × managers cannot exceed ${context.castCount} cast members. The size locks when the draft begins.` : 'The draft has started, so roster size is locked.'}</p><div class="modal-actions"><button id="saveWorkspaceSettings">Save settings</button></div><div class="workspace-danger-zone"><h3>Delete league</h3><p class="sub">Permanently remove this league, its teams, invitations, draft, trades, and scoring history for every manager. This cannot be undone.</p><button id="deleteWorkspaceLeague" class="danger">Delete league</button></div>`);
  $('#workspaceAutoRoster').addEventListener('change', () => {
    $('#workspaceRosterSize').disabled = $('#workspaceAutoRoster').checked;
  });
  $('#saveWorkspaceSettings').addEventListener('click', () => runAction(
    () => db.rpc('update_league_workspace', { p_league_id: context.leagueId,
      p_name: $('#workspaceLeagueName').value.trim(),
      p_roster_size: $('#workspaceAutoRoster').checked ? null : Number($('#workspaceRosterSize').value),
      p_auto_roster: $('#workspaceAutoRoster').checked }),
    async () => { $('#modal').close(); location.reload(); },
    $('#saveWorkspaceSettings'),
  ));
  $('#deleteWorkspaceLeague')?.addEventListener('click', () => {
    dialog(`<h2>Delete ${safe(context.leagueName)}?</h2><p class="sub">This permanently removes the league and all its draft and trade history for every manager. Type its name to confirm.</p><label>League name<input id="confirmDeleteLeagueName" autocomplete="off"></label><button id="confirmDeleteLeague" class="danger" disabled>Delete league permanently</button>`);
    $('#confirmDeleteLeagueName').addEventListener('input', () => {
      $('#confirmDeleteLeague').disabled = $('#confirmDeleteLeagueName').value.trim() !== context.leagueName;
    });
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
  dialog(`<p class="eyebrow">${safe(context.leagueName)}</p><h2>Invite Players</h2><p class="sub">${context.memberCount >= 6 ? 'This league is full. You can still review or cancel pending invitations.' : 'Search by username or create a link for someone who does not have an account yet.'}</p><label>Search username<input id="inviteUsernameSearch" autocomplete="off" placeholder="Search @username" ${context.memberCount >= 6 ? 'disabled' : ''}></label><div id="inviteSearchResults"></div><div class="workspace-invite-link-actions"><button id="generateInviteLink" class="secondary" ${context.memberCount >= 6 ? 'disabled' : ''}>Generate / replace invite link</button><button id="revokeInviteLink" class="secondary" hidden>Revoke link</button></div><div id="generatedInviteLink"></div><p id="inviteLinkStatus" class="sub"></p><div id="pendingLeagueInvites"></div>`);
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
  const updateLinkStatus = async () => {
    const result = await db.from('league_invite_links').select('id,expires_at')
      .eq('league_id', context.leagueId).is('revoked_at', null).maybeSingle();
    if (!$('#inviteLinkStatus')) return;
    const active = !result.error && result.data && new Date(result.data.expires_at) > new Date();
    $('#inviteLinkStatus').textContent = active
      ? `An invite link is active until ${new Date(result.data.expires_at).toLocaleDateString()}. Generate a new one to replace it.`
      : 'No active invite link.';
    $('#revokeInviteLink').hidden = !active;
  };
  updateLinkStatus();
  const search = $('#inviteUsernameSearch');
  let searchVersion = 0;
  search.addEventListener('input', async () => {
    const term = search.value.trim().toLowerCase().replace(/^@/, '');
    const version = ++searchVersion;
    if (term.length < 2) { $('#inviteSearchResults').innerHTML = ''; return; }
    const result = await db.from('profile_directory').select('user_id,username,display_name,avatar_url')
      .ilike('username', `${term}%`).limit(8);
    if (version !== searchVersion || !search.isConnected || !$('#inviteSearchResults')) return;
    $('#inviteSearchResults').innerHTML = result.error ? '<p class="sub">Search is unavailable.</p>'
      : (result.data || []).map((profile) => `<div class="workspace-profile-result"><span><b>${safe(profile.display_name)}</b><small>@${safe(profile.username)}</small></span><button data-invite-username="${safe(profile.username)}">Invite</button></div>`).join('') || '<p class="sub">No matching usernames.</p>';
    $('#inviteSearchResults').querySelectorAll('[data-invite-username]').forEach((button) => button.addEventListener('click', () => runAction(
      () => db.rpc('invite_username', { p_league_id: context.leagueId, p_username: button.dataset.inviteUsername }),
      async () => { search.value = ''; $('#inviteSearchResults').innerHTML = ''; await drawPending(); },
      button,
    )));
  });
  $('#generateInviteLink').onclick = async () => {
    const button = $('#generateInviteLink');
    button.disabled = true;
    const { data: token, error } = await db.rpc('regenerate_league_invite_link', { p_league_id: context.leagueId });
    if (!button.isConnected) return;
    button.disabled = false;
    if (error) return dialog(`<h2>Couldn’t create link</h2><p>${safe(errorMessage(error))}</p>`);
    const url = new URL(location.href);
    url.search = '';
    url.searchParams.set('join', token);
    url.hash = '#standings';
    $('#generatedInviteLink').innerHTML = `<label>Share this link<input id="inviteLinkValue" readonly value="${safe(url.toString())}"></label><button id="copyInviteLink">Copy link</button><p class="sub">Generating another link revokes this one. The link expires in 14 days.</p>`;
    updateLinkStatus();
    $('#copyInviteLink').addEventListener('click', async () => {
      await navigator.clipboard.writeText(url.toString());
      $('#copyInviteLink').textContent = 'Copied';
    });
  };
  $('#revokeInviteLink').addEventListener('click', () => runAction(
    () => db.rpc('revoke_league_invite_link', { p_league_id: context.leagueId }),
    async () => { $('#generatedInviteLink').innerHTML = ''; updateLinkStatus(); },
    $('#revokeInviteLink'),
  ));
}

export async function renderSecondaryLeague(context) {
  if (!context.signedIn || context.leagueId === defaultLeagueId) return;
  const version = ++workspaceVersion;
  ++tradeRequestVersion;
  refreshCurrentWorkspaceTrades = null;
  const refresh = () => renderSecondaryLeague(context);
  for (const id of ['#standingsContent', '#publicTeamResults', '#commissionerTeamResults', '#scoreDeskContent']) {
    if ($(id)) $(id).innerHTML = '<div class="card pad">Loading league…</div>';
  }
  try {
    const data = await loadWorkspaceData(context);
    if (version !== workspaceVersion) return;
    const liveContext = { ...context, leagueName: data.league.name,
      leagueStatus: data.league.status, rosterSize: data.league.roster_size,
      rosterSizeOverridden: data.league.roster_size_overridden,
      memberCount: data.members.length, castCount: data.cast.length,
      scoringStartsAfterWeek: data.league.scoring_starts_after_week };
    const assignmentMap = new Map(data.assignments.map((assignment) => [assignment.cast_member_id, assignment.fantasy_team_id]));
    const memberByTeam = new Map(data.members.map((member) => [member.fantasy_team_id, member]));
    const score = scoreLeague(data, liveContext);
    renderStandings(liveContext, data, score, assignmentMap, memberByTeam, refresh);
    renderMyTeam(liveContext, data, score, assignmentMap, memberByTeam, refresh);
    const refreshTrades = () => {
      if (version === workspaceVersion && !document.hidden && !$('#modal')?.open && $('#workspaceTradeCenter')) {
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
    if (['drafting', 'active'].includes(liveContext.leagueStatus)) {
      workspaceRefreshTimer = setInterval(() => { if (!document.hidden) refresh(); }, 30000);
    }
    if (liveContext.leagueStatus === 'active') {
      workspaceTradeRefreshTimer = setInterval(refreshTrades, 10000);
    }
  } catch (error) {
    if (version !== workspaceVersion) return;
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
  ++workspaceVersion;
  ++tradeRequestVersion;
  clearInterval(workspaceRefreshTimer);
  clearInterval(workspaceTradeRefreshTimer);
  workspaceRefreshTimer = null;
  workspaceTradeRefreshTimer = null;
  refreshCurrentWorkspaceTrades = null;
}

window.addEventListener('focus', () => refreshCurrentWorkspaceTrades?.());
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) refreshCurrentWorkspaceTrades?.();
});
$('#modal')?.addEventListener('close', () => refreshCurrentWorkspaceTrades?.());
