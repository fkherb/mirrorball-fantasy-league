import { db } from './supabase-client.js';
import { standingCard, scoreRows, overviewTeamDetail, highlightCards, teamCard, castRosterRow, danceCard, teamPage } from './postdraft-view.js?v=20260926-league-parity-v17';

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
let selectedTeamWeekId = 'all';
let workspaceTradeRefreshTimer = null;
let refreshCurrentWorkspaceTrades = null;
let tradeRequestVersion = 0;
let hubVersion = 0;
let workspaceActionPending = false;
let selectedDanceWeekId = null;
let tradeTab = 'active';
let workspaceRosterFilter = 'all';
let selectedWorkspaceOverviewTeamId = null;

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

function openWorkspaceCastProfile(cast, teamName = 'Available cast') {
  dialog(`<div class="workspace-profile-modal"><img src="${safe(castImage(cast))}" alt=""><div><p class="eyebrow">${safe(cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role)}</p><h2>${safe(cast.name)}</h2><p class="sub">${safe(teamName)}</p>${cast.bio ? `<p>${safe(cast.bio)}</p>` : ''}${cast.career_highlights ? `<p><b>Career highlights</b><br>${safe(cast.career_highlights)}</p>` : ''}${cast.mirrorball_wins ? `<p><b>Past Mirrorball wins:</b> ${Number(cast.mirrorball_wins) || 0}</p>` : ''}</div></div>`);
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
    dialog('<div class="workspace-create-league"><p class="eyebrow">New league</p><h2>Create a League</h2><p class="sub">Start a private league, then invite your friends.</p><label>League name<input id="newLeagueName" maxlength="80" placeholder="e.g. Saturday Night League"></label><div class="workspace-create-facts"><span><b>3–6 managers</b><small>Invite friends after creating</small></span><span><b>Auto-sized rosters</b><small>Adjustable before the draft</small></span></div><div class="modal-actions"><button id="confirmCreateLeague">Create league</button></div></div>');
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
  const pointsByWeekCast = new Map();
  const scoringWeeks = context.leagueStatus === 'active'
    ? data.weeks.filter((week) => week.is_complete && week.number > context.scoringStartsAfterWeek)
    : [];
  if (scoringWeeks.some((week) => !data.snapshots.some((snapshot) => snapshot.week_id === week.id))) {
    throw new Error('A completed week is missing this league’s roster snapshot. Scoring is paused until it is repaired.');
  }
  data.scores.forEach((score) => scoreByDance.set(score.dance_id, (scoreByDance.get(score.dance_id) || 0) + Number(score.score || 0)));
  const add = (castId, weekId, amount, source) => {
    const week = weekById.get(weekId);
    if (context.leagueStatus !== 'active' || !week || !week.is_complete || week.number <= context.scoringStartsAfterWeek) return;
    const snapshot = snapshotByKey.get(`${weekId}:${castId}`);
    if (!snapshot) throw new Error(`Week ${week.number} is missing a cast roster snapshot. Scoring is paused until it is repaired.`);
    const teamId = snapshot.fantasy_team_id;
    if (!teamId || !totalByTeam.has(teamId)) return;
    totalByTeam.set(teamId, totalByTeam.get(teamId) + amount);
    const castPoints = pointsByTeamCast.get(teamId);
    castPoints.set(castId, (castPoints.get(castId) || 0) + amount);
    const key = `${weekId}:${teamId}`;
    pointsByWeekTeam.set(key, (pointsByWeekTeam.get(key) || 0) + amount);
    const castKey = `${weekId}:${castId}`;
    const detail = pointsByWeekCast.get(castKey) || { official: 0, appearances: 0 };
    detail[source] += amount;
    pointsByWeekCast.set(castKey, detail);
  };
  data.dances.filter((dance) => dance.kind === 'competitive').forEach((dance) => {
    const pair = pairById.get(dance.partnership_id);
    if (!pair) return;
    const score = scoreByDance.get(dance.id) || 0;
    add(pair.star_id, dance.week_id, score, 'official');
    add(pair.pro_id, dance.week_id, score, 'official');
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
    add(cast.id, dance.week_id, rate, 'appearances');
  });
  return { totalByTeam, pointsByTeamCast, pointsByWeekTeam, pointsByWeekCast, scoringWeeks, rateByName, scoreByDance, snapshotByKey };
}

async function loadWorkspaceData(context) {
  const leagueId = context.leagueId;
  const queries = {
    league: db.from('leagues').select('id,name,status,roster_size,roster_size_overridden,scoring_starts_after_week,draft_pick_deadline_at,draft_paused_at').eq('id', leagueId).single(),
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
    picks: db.from('league_draft_picks').select('pick_number,round_number,fantasy_team_id,cast_member_id,picked_at,is_auto_pick').eq('league_id', leagueId).order('pick_number'),
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
  $('#standingsLeagueName').textContent = context.leagueName;
  $('#standingsSubtitle').textContent = isSetup
    ? 'Your league is getting ready for its draft.'
    : context.leagueStatus === 'drafting' ? 'The draft is underway. Standings begin after every roster is filled.'
      : score.scoringWeeks.length ? `Through ${score.scoringWeeks.at(-1).title || (score.scoringWeeks.at(-1).theme ? `${score.scoringWeeks.at(-1).theme} Week` : `Week ${score.scoringWeeks.at(-1).number}`)} · current fantasy-team totals` : 'The season is ready. Scores will appear after the first completed show.';
  const turn = draftTurn(data.order, data.picks, context.rosterSize);
  const setupPanel = isSetup ? `<section class="card pad workspace-setup-panel"><p class="eyebrow">Before the draft</p><h2>Build your league</h2><p class="sub">${data.members.length} of 3–6 managers joined. ${data.members.length < 3 ? `Invite ${3 - data.members.length} more to start.` : 'Your league can start its draft whenever the owner is ready.'} Roster size is currently ${context.rosterSize} cast per team${context.rosterSizeOverridden ? ' (custom)' : ' (automatic)'}.</p><div class="workspace-setup-facts"><span><b>${data.members.length}</b> managers</span><span><b>${context.rosterSize}</b> draft rounds</span><span><b>${data.cast.length}</b> cast in pool</span></div>${context.leagueRole === 'owner' ? `<div class="modal-actions">${data.members.length < 6 ? '<button id="overviewInvitePlayers">Invite players</button>' : ''}<button id="overviewLeagueSettings" class="secondary">League settings</button></div>` : '<p class="sub">The league owner can invite managers and start the draft when at least three have joined.</p>'}</section>` : isDrafting ? `<section class="card pad workspace-setup-panel"><p class="eyebrow">${context.draftPaused ? 'Draft paused' : 'Draft in progress'}</p><h2>Round ${turn?.round || context.rosterSize} of ${context.rosterSize}</h2><p class="sub">${data.picks.length} of ${data.order.length * context.rosterSize} picks complete. ${context.draftPaused ? 'The clock and picks are paused until the league owner resumes.' : turn ? `${safe(memberByTeam.get(turn.teamId)?.display_name || 'The next manager')} is on the clock.` : 'Every roster is filled.'}</p><a class="workspace-inline-link" href="#teams" id="overviewOpenDraft">View the draft</a></section>` : !score.scoringWeeks.length ? '<section class="card pad workspace-setup-panel"><p class="eyebrow">Season ready</p><h2>Waiting for the first completed show</h2><p class="sub">Your draft teams are set. Weekly points and highlights will appear after a show is completed.</p></section>' : '';
  const scored = context.leagueStatus === 'active' && score.scoringWeeks.length > 0;
  const castPoints = (team) => data.cast.map((cast) => ({ cast, points: score.pointsByTeamCast.get(team.id)?.get(cast.id) || 0 }))
    .filter(({ cast, points }) => points || assignmentMap.get(cast.id) === team.id)
    .sort((a, b) => b.points - a.points || a.cast.name.localeCompare(b.cast.name));
  if (scored && !rows.some((team) => team.id === selectedWorkspaceOverviewTeamId)) selectedWorkspaceOverviewTeamId = rows[0]?.id;
  $('#standingsContent').innerHTML = scored ? `<div class="standings-grid">${rows.map((team, index) => {
    const leaders = castPoints(team);
    const tied = rows.filter((item) => item.points === rows[0].points).length > 1 && team.points === rows[0].points;
    const rank = rows.findIndex((item) => item.points === team.points) + 1;
    return standingCard({ id: team.id, rank, manager: team.manager,
      name: team.team_name || `${team.manager.split(' ')[0]}'s Team`,
      contributors: leaders.map(({ cast, points }) => ({ name: cast.name, points })), total: team.points,
      selected: team.id === selectedWorkspaceOverviewTeamId, leader: index === 0, tied });
  }).join('')}</div>` : `${setupPanel}${rows.length ? `<div class="workspace-standings-list">${rows.map((team) => `<button type="button" class="card workspace-standing-card" data-workspace-standing="${team.id}" aria-label="View ${safe(team.team_name || team.manager)} roster"><span class="workspace-rank">•</span><span><small>${safe(team.manager)}</small><b>${safe(team.team_name || `${team.manager.split(' ')[0]}'s Team`)}</b></span><strong>${[...assignmentMap.values()].filter((id) => id === team.id).length}/${context.rosterSize} cast</strong></button>`).join('')}</div>` : '<div class="card pad">No teams yet.</div>'}`;
  $('#overviewInvitePlayers')?.remove();
  $('#overviewLeagueSettings')?.addEventListener('click', () => openLeagueSettings(context, refresh));
  $('#overviewOpenDraft')?.addEventListener('click', (event) => { event.preventDefault(); $('#myTeamNav').click(); });
  const detailMarkup = (team) => {
    const leaders = castPoints(team).slice(0, 5);
    const castRows = leaders.map(({ cast, points }) => {
      const parts = score.scoringWeeks.reduce((total, week) => {
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
      manager: team.manager, total: team.points, castRows });
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
    ? 'Invitations and league settings are open. The draft begins when 3–6 managers have joined.'
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
  const draftStrip = context.leagueStatus === 'setup'
    ? `<div class="workspace-draft-strip"><div><small>Draft setup</small><strong>${data.members.length} of 3–6 managers joined</strong><p class="sub">${context.rosterSize} rounds · ${context.rosterSizeOverridden ? 'custom' : 'automatic'} roster size</p></div>${context.leagueRole === 'owner' ? `<button id="startDraftFromTeam" ${data.members.length >= 3 && data.members.length <= 6 ? '' : 'disabled'}>Start draft</button>` : ''}</div>`
    : context.leagueStatus === 'drafting'
      ? `<div class="workspace-draft-strip workspace-draft-status"><div><small>Round ${currentRound} of ${context.rosterSize} · Pick ${turn?.pickNumber || '—'}</small><strong>${context.draftPaused ? 'Draft paused' : isYourTurn ? 'You are on the clock' : `${safe(memberByTeam.get(turn?.teamId)?.display_name || 'Next manager')} is on the clock`}</strong><p class="sub">${context.draftPaused ? 'The league owner paused the draft. No picks or automatic selections can happen until it resumes.' : 'Each manager has two minutes to pick before the draft selects a random available cast member.'}</p>${context.leagueRole === 'owner' ? `<button type="button" id="toggleDraftPause" class="secondary">${context.draftPaused ? 'Resume draft' : 'Pause draft'}</button>` : ''}</div><div class="workspace-draft-timer"><small>${context.draftPaused ? 'Draft clock' : 'Time left'}</small><strong id="workspaceDraftClock" aria-live="off">${context.draftPaused ? 'Paused' : '02:00'}</strong></div></div>`
      : seasonSummary;
  const canClaim = isYourTurn || context.leagueStatus === 'active';
  const castScrollTop = body.querySelector('.workspace-available-list')?.scrollTop || 0;
  body.innerHTML = `<section class="card public-team-detail workspace-team-detail">${draftStrip}${context.leagueStatus === 'drafting' ? `<section class="workspace-draft-rounds"><div class="public-section-head"><div><p class="eyebrow">Draft board</p><h3>Round ${draftRound} picks</h3></div><span>${data.picks.length} of ${data.order.length * context.rosterSize} picked</span></div><div class="workspace-round-tabs" role="group" aria-label="Draft rounds">${Array.from({ length: context.rosterSize }, (_, index) => `<button type="button" data-draft-round="${index + 1}" class="${draftRound === index + 1 ? 'selected' : ''}" aria-pressed="${draftRound === index + 1}">Round ${index + 1}</button>`).join('')}</div><div class="workspace-round-picks">${roundSlots}</div></section>` : ''}<div class="public-team-columns"><section><div class="public-section-head"><div><p class="eyebrow">Roster</p><h3>Team Roster · ${roster.length}/${context.rosterSize}</h3></div></div><div class="workspace-cast-list">${roster.map((member) => castTile(member, context.leagueStatus === 'active' ? `<strong class="workspace-points">${score.pointsByTeamCast.get(ownTeam.id)?.get(member.id) || 0} pts</strong>` : '')).join('') || '<p class="sub">Your picks will appear here.</p>'}</div></section><div class="team-side-column"><section class="available-cast-panel"><div class="public-section-head"><div><p class="eyebrow">${context.leagueStatus === 'drafting' ? 'Draft pool' : 'Free agents'}</p><h3>Available Cast</h3></div><span>${available.length} available</span></div><p class="sub">${isYourTurn ? 'It is your turn. Claim one cast member below.' : context.draftPaused ? 'The draft is paused. Claims reopen when the owner resumes.' : context.leagueStatus === 'drafting' ? 'Claims open when it is your turn.' : context.leagueStatus === 'active' ? 'Claim a cast member by releasing one from your roster.' : 'Claims open after the draft starts.'}</p><div class="workspace-available-list">${available.map((member) => castTile(member, canClaim ? `<button data-workspace-claim="${member.id}">Claim</button>` : '')).join('') || '<p class="sub">No cast members are available.</p>'}</div></section>${context.leagueStatus === 'active' ? '<section id="workspaceTradeCenter" class="card pad workspace-trades">Loading trades…</section>' : ''}</div></div></section>`;
  if (context.leagueStatus === 'active') {
    const availableMarkup = available.map((member) => `<article class="league-cast-person available-cast-person"><button type="button" class="available-profile-button" data-workspace-available-cast="${member.id}" aria-label="View ${safe(member.name)} profile"><img src="${safe(castImage(member))}" style="object-position:${Number(member.image_position) || 50}% center" alt=""><span><strong>${safe(member.name)}</strong><small>${safe(member.role === 'DWTS Next Pro' ? 'Next Pro' : member.role)}</small></span></button><button type="button" class="claim-cast-button" data-workspace-claim="${member.id}">Claim</button></article>`).join('');
    body.innerHTML = teamPage({ weekHistory, total: selectedTotal, period: selectedWeek ? 'week' : 'season',
      rosterRows: `${selectedWeek?.is_complete ? `<p class="sub workspace-roster-note">This roster was locked when Week ${selectedWeek.number} was completed.</p>` : ''}${scoreRows(rosterScoreRows, { withImages: true, imageFor: castImage, historicalJudges: !selectedWeek })}`,
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
  if (body.querySelector('.workspace-available-list')) body.querySelector('.workspace-available-list').scrollTop = castScrollTop;
  if (context.leagueStatus !== 'active') {
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
  if (context.leagueStatus === 'drafting') updateDraftClock(data.league.draft_pick_deadline_at, null, context.draftPaused);
  $('#toggleDraftPause')?.addEventListener('click', () => runAction(
    () => db.rpc('set_league_draft_paused', { p_league_id: context.leagueId, p_paused: !context.draftPaused }),
    refresh,
    $('#toggleDraftPause'),
  ));
  $('#startDraftFromTeam')?.addEventListener('click', () => confirmStartDraft(context));
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
  const competitiveCount = weekDances.filter((dance) => dance.kind === 'competitive').length;
  content.innerHTML = `<div class="score-week-head card"><div class="week-heading"><p class="eyebrow">Week ${week.number}</p><div class="week-title-line"><h2>${safe(week.title || (week.theme ? `${week.theme} Week` : `Week ${week.number}`))}</h2></div><p class="sub">${week.is_complete ? 'Completed show' : 'Upcoming show · scores pending'}</p></div><div class="week-summary"><span>${competitiveCount} competitive</span>${weekDances.length > competitiveCount ? `<span>${weekDances.length - competitiveCount} performances</span>` : ''}<span class="${week.is_complete ? 'week-complete' : ''}">${week.is_complete ? 'Complete' : 'Upcoming'}</span></div></div><div class="dance-list">${weekDances.map((dance) => {
    const pair = pairById.get(dance.partnership_id);
    const names = pair ? `${nameFor(pair.star_id)} & ${nameFor(pair.pro_id)}` : dance.name || 'Performance';
    const judges = data.scores.filter((item) => item.dance_id === dance.id);
    const castNames = data.appearances.filter((item) => item.dance_id === dance.id)
      .map((appearance) => nameFor(appearance.cast_member_id));
    return danceCard({ id: dance.id, kind: dance.kind, title: names,
      danceType: dance.dance_type, song: dance.song, scores: judges, castNames,
      scoreImage: (value) => `Images/Judges Scores/${Number(value)}.png?v=20260921-optimized`,
      pending: !week.is_complete && !judges.length });
  }).join('') || '<div class="card pad">No dances recorded for this week.</div>'}</div>`;
  content.querySelectorAll('[data-dance-detail]').forEach((button) => {
    const open = () => {
    const dance = weekDances.find((item) => item.id === button.dataset.danceDetail);
    const pair = pairById.get(dance.partnership_id);
    const involved = pair ? [pair.star_id, pair.pro_id] : data.appearances.filter((item) => item.dance_id === dance.id).map((item) => item.cast_member_id);
    const judges = data.scores.filter((item) => item.dance_id === dance.id);
    dialog(`<p class="eyebrow">Week ${week.number} · ${safe(dance.dance_type || dance.kind)}</p><h2>${safe(pair ? `${nameFor(pair.star_id)} & ${nameFor(pair.pro_id)}` : dance.name || 'Performance')}</h2><p class="sub">${safe(dance.song || 'Song not set')}</p><div class="workspace-dance-judges">${judges.map((judge) => `<span>${safe(judge.judge_name)} <b>${judge.score}</b></span>`).join('') || '<p>Scores pending.</p>'}</div><h3>Cast and fantasy teams</h3>${involved.map((id) => `<p>${safe(nameFor(id))} · ${safe(teamFor(id))}</p>`).join('')}${data.appearances.filter((item) => item.dance_id === dance.id && !involved.includes(item.cast_member_id)).map((item) => `<p>${safe(nameFor(item.cast_member_id))} · ${safe(teamFor(item.cast_member_id))}</p>`).join('')}`);
    };
    button.addEventListener('click', open);
    button.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); open(); } });
  });
}

async function renderLeague(context, data, assignmentMap, memberByTeam, score, refresh) {
  const renderVersion = workspaceVersion;
  $('#leagueName').textContent = context.leagueName;
  $('#leagueTeamCount').textContent = data.teams.length;
  $('#leagueCastCount').textContent = data.cast.length;
  $('#leagueAvailableCount').textContent = data.cast.length - assignmentMap.size;
  $('#league .workspace-league-draft-banner')?.remove();
  if (context.leagueStatus === 'drafting') {
    const turn = draftTurn(data.order, data.picks, context.rosterSize);
    const banner = document.createElement('div');
    banner.className = 'workspace-league-draft-banner';
    banner.innerHTML = `<div><p class="eyebrow">${context.draftPaused ? 'Draft paused' : 'Draft in progress'} · Round ${turn?.round || context.rosterSize}</p><strong>${context.draftPaused ? 'The clock is stopped' : `${safe(memberByTeam.get(turn?.teamId)?.display_name || 'The next manager')} is on the clock`}</strong><small>${data.picks.length} of ${data.order.length * context.rosterSize} picks complete</small></div><button type="button" id="leagueOpenDraft">Open draft</button>`;
    $('#league .league-at-a-glance').after(banner);
    banner.querySelector('button').addEventListener('click', () => $('#myTeamNav').click());
  }
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
    const managerName = member?.display_name || team.manager_name;
    const teamName = team.team_name || `${managerName.split(' ')[0]}'s Team`;
    return teamCard({ id: team.id, manager: managerName, name: teamName,
      roster: roster.map((cast) => ({ name: cast.name, role: cast.role === 'DWTS Next Pro' ? 'Next Pro' : cast.role })),
      emptyMessage: context.leagueStatus === 'setup' ? 'Draft not started' : context.leagueStatus === 'drafting' ? 'Waiting for first pick' : 'No cast on this team',
      footerHtml: context.leagueRole === 'owner' && context.leagueStatus === 'setup' && member?.member_role === 'member'
        ? `<button class="secondary workspace-remove-manager" data-remove-member="${member.user_id}">Remove manager</button>` : '' });
  }).join('');
  $('#commissionerTeamResults').querySelectorAll('[data-team-detail]').forEach((card) => {
    const open = () => {
      const team = data.teams.find((item) => item.id === card.dataset.teamDetail);
      const managerName = memberByTeam.get(team.id)?.display_name || team.manager_name;
      const teamName = team.team_name || `${managerName.split(' ')[0]}'s Team`;
      const roster = data.cast.filter((cast) => assignmentMap.get(cast.id) === team.id);
      dialog(`<div class="team-detail-head"><div><p class="eyebrow">${safe(managerName)}</p><h2>${safe(teamName)}</h2><p class="sub">Current roster</p></div></div>${roster.length ? `<div class="team-detail-grid">${roster.map((cast) => `<article class="team-detail-member" data-workspace-team-cast="${cast.id}" tabindex="0" role="button"><img src="${safe(castImage(cast))}" alt=""><div><b>${safe(cast.name)}</b><span>${safe(cast.role)}</span></div><i aria-hidden="true">›</i></article>`).join('')}</div>` : '<p class="sub">No cast members assigned yet.</p>'}`);
      $('#modalBody').querySelectorAll('[data-workspace-team-cast]').forEach((tile) => {
        const show = () => openWorkspaceCastProfile(data.cast.find((cast) => cast.id === tile.dataset.workspaceTeamCast), teamName);
        tile.addEventListener('click', show);
        tile.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); show(); } });
      });
    };
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
  $('#roleRatesContent').innerHTML = `<div class="card role-rate-table"><div class="role-rate-heading"><span>Cast role</span><span>Appearance points</span></div>${data.rates.map((rate) => `<div class="role-rate-row"><span>${safe(rateByRole.get(rate.role_id)?.name || 'Role')}</span><strong>${rate.appearance_points == null ? 'Varies' : `+${rate.appearance_points}`}</strong></div>`).join('')}</div>`;
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
    async () => { $('#modal').close(); selectedDraftRound = 1; await renderSecondaryLeague(context, { silent: true }); },
    $('#confirmStartDraft'),
  ));
}

function openLeagueSettings(context, refresh) {
  const isSetup = context.leagueStatus === 'setup';
  const rosterOptions = isSetup ? `<div class="workspace-roster-setting"><label class="workspace-roster-size">Roster size<input id="workspaceRosterSize" type="number" min="1" max="30" inputmode="numeric" value="${context.rosterSize}" ${context.rosterSizeOverridden ? '' : 'disabled'}></label><label class="workspace-auto-size"><input id="workspaceAutoRoster" type="checkbox" ${context.rosterSizeOverridden ? '' : 'checked'}>Auto-size</label></div><p class="sub workspace-roster-help">${context.memberCount} manager${context.memberCount === 1 ? '' : 's'} joined. Roster size equals draft rounds; Auto-size adjusts it as managers join. A manual size × managers cannot exceed ${context.castCount} cast members.</p>` : '';
  dialog(`<p class="eyebrow">League settings</p><h2>Edit ${safe(context.leagueName)}</h2><label>League name<input id="workspaceLeagueName" maxlength="80" value="${safe(context.leagueName)}"></label>${rosterOptions}<div class="modal-actions"><button id="saveWorkspaceSettings">Save changes</button></div><div class="workspace-danger-zone"><h3>Delete league</h3><p class="sub">Permanently remove this league, its teams, invitations, draft, trades, and scoring history for every manager. This cannot be undone.</p><button id="deleteWorkspaceLeague" class="danger">Delete league</button></div>`);
  let manualRosterSize = context.rosterSize;
  $('#workspaceAutoRoster')?.addEventListener('change', () => {
    const field = $('#workspaceRosterSize');
    const automatic = $('#workspaceAutoRoster').checked;
    if (automatic) {
      manualRosterSize = Number(field.value) || context.rosterSize;
      const suggested = context.memberCount >= 5 ? 8 : context.memberCount === 4 ? 10 : 12;
      field.value = Math.max(1, Math.min(suggested,
        Math.floor(context.castCount / Math.max(3, context.memberCount))));
    } else field.value = manualRosterSize;
    field.disabled = automatic;
  });
  $('#saveWorkspaceSettings').addEventListener('click', () => runAction(
    () => db.rpc('update_league_workspace', { p_league_id: context.leagueId,
      p_name: $('#workspaceLeagueName').value.trim(),
      p_roster_size: isSetup ? $('#workspaceAutoRoster').checked ? null : Number($('#workspaceRosterSize').value)
        : context.rosterSize,
      p_auto_roster: isSetup ? $('#workspaceAutoRoster').checked : null }),
    async () => { $('#modal').close(); location.reload(); },
    $('#saveWorkspaceSettings'),
  ));
  $('#deleteWorkspaceLeague')?.addEventListener('click', () => {
    dialog(`<h2>Delete ${safe(context.leagueName)}?</h2><p class="sub">This permanently removes the league for every manager. To enable Delete, type <strong>${safe(context.leagueName)}</strong> exactly as shown.</p><label>Type ${safe(context.leagueName)} to confirm<input id="confirmDeleteLeagueName" autocomplete="off" aria-describedby="deleteLeagueHint"></label><p id="deleteLeagueHint" class="sub" role="status">Delete is unavailable until the name matches.</p><div class="modal-actions"><button id="cancelDeleteLeague" type="button" class="secondary">Cancel</button><button id="confirmDeleteLeague" class="danger" disabled>Delete league permanently</button></div>`);
    $('#confirmDeleteLeagueName').focus();
    $('#cancelDeleteLeague').addEventListener('click', () => $('#modal').close());
    $('#confirmDeleteLeagueName').addEventListener('input', () => {
      const matches = $('#confirmDeleteLeagueName').value.trim() === context.leagueName;
      $('#confirmDeleteLeague').disabled = !matches;
      $('#deleteLeagueHint').textContent = matches ? 'Name matched. You can now delete this league.' : 'Delete is unavailable until the name matches.';
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

export async function renderSecondaryLeague(context, { silent = false } = {}) {
  if (!context.signedIn || context.leagueId === defaultLeagueId) return;
  const version = ++workspaceVersion;
  ++tradeRequestVersion;
  refreshCurrentWorkspaceTrades = null;
  const refresh = () => renderSecondaryLeague(context, { silent: true });
  if (!silent) {
    for (const id of ['#standingsContent', '#publicTeamResults', '#commissionerTeamResults', '#scoreDeskContent']) {
      if ($(id)) $(id).innerHTML = '<div class="card pad">Loading league…</div>';
    }
  }
  try {
    const data = await loadWorkspaceData(context);
    if (version !== workspaceVersion) return;
    const liveContext = { ...context, leagueName: data.league.name,
      leagueStatus: data.league.status, rosterSize: data.league.roster_size,
      draftPaused: Boolean(data.league.draft_paused_at),
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
    refreshCurrentWorkspaceDraft = null;
    if (liveContext.leagueStatus === 'setup' || liveContext.leagueStatus === 'drafting') {
      const knownStatus = liveContext.leagueStatus;
      const knownPickCount = data.picks.length;
      const knownPaused = liveContext.draftPaused;
      const pollDraft = async () => {
        if (document.hidden || workspaceDraftPollInFlight || version !== workspaceVersion) return;
        workspaceDraftPollInFlight = true;
        try {
          const { data: state, error } = await db.rpc('advance_league_draft_clock', { p_league_id: liveContext.leagueId });
          if (error) throw error;
          if (version !== workspaceVersion) return;
          const statePaused = state.status === 'drafting' && !state.deadline_at;
          if (state.status !== knownStatus || state.pick_count !== knownPickCount || statePaused !== knownPaused) {
            if (state.pick_count !== knownPickCount) selectedDraftRound = null;
            await refresh();
          } else if (state.status === 'drafting') updateDraftClock(state.deadline_at, state.server_now, statePaused);
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
      workspaceRefreshTimer = setInterval(() => { if (!document.hidden) refresh(); }, 30000);
    }
    if (liveContext.leagueStatus === 'active') {
      workspaceTradeRefreshTimer = setInterval(refreshTrades, 10000);
    }
  } catch (error) {
    if (version !== workspaceVersion) return;
    if (silent) { console.warn('League refresh unavailable', error); return; }
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
  window.removeEventListener('resize', window.workspaceOverviewResize);
  window.workspaceOverviewResize = null;
}

window.addEventListener('focus', () => { refreshCurrentWorkspaceTrades?.(); refreshCurrentWorkspaceDraft?.(); });
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) { refreshCurrentWorkspaceTrades?.(); refreshCurrentWorkspaceDraft?.(); }
});
$('#modal')?.addEventListener('close', () => refreshCurrentWorkspaceTrades?.());
