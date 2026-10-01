// Pure scorers for the original league and league-scoped workspaces.
export function roleForWeek(member, week, weeks) {
  if (!member?.role?.startsWith('Eliminated')) return member?.role || '';
  const eliminatedWeek = weeks.find((item) => item.id === member.eliminated_week_id);
  if (week && eliminatedWeek && week.number <= eliminatedWeek.number) return member.role.replace('Eliminated ', '');
  return member.role;
}

export function appearanceValue(member, roleMap, week, weeks, snapshot = null) {
  if (!member) return 0;
  if (member.is_hough) return Number(roleMap.get('Hough')?.appearance_points) || 0;
  const role = snapshot?.cast_role || roleForWeek(member, week, weeks);
  if (role === 'Surprise') {
    if (member.surprise_base_role) return (Number(roleMap.get(member.surprise_base_role)?.appearance_points) || 0) + 2;
    return Number(member.custom_appearance_points) || 0;
  }
  return Number(roleMap.get(role)?.appearance_points) || 0;
}

export function sharedAppearanceRate(member, snapshot, rateByName) {
  if (!member) return 0;
  if (member.is_hough) return rateByName.get('Hough') || 0;
  const role = snapshot?.cast_role || member.role;
  if (role === 'Surprise') {
    if (member.surprise_base_role) return (rateByName.get(member.surprise_base_role) || 0) + 2;
    return Number(member.custom_appearance_points) || 0;
  }
  return rateByName.get(role) || 0;
}

export function calculateLeaguePoints(data) {
  const memberById = new Map(data.members.map((member) => [member.id, member]));
  const roleMap = new Map(data.roles.map((role) => [role.name, role]));
  const partnershipById = new Map(data.partnerships.map((partnership) => [partnership.id, partnership]));
  const danceById = new Map(data.dances.map((dance) => [dance.id, dance]));
  const weekById = new Map(data.weeks.map((week) => [week.id, week]));
  const snapshotByWeekMember = new Map((data.rosterSnapshots || []).map((snapshot) => [`${snapshot.week_id}:${snapshot.cast_member_id}`, snapshot]));
  const scoresByDance = new Map();
  const memberPoints = new Map(data.members.map((member) => [member.id, 0]));
  const weekMemberPoints = new Map();
  const add = (memberId, weekId, kind, points) => {
    if (!memberById.has(memberId)) return;
    memberPoints.set(memberId, (memberPoints.get(memberId) || 0) + points);
    if (!weekMemberPoints.has(weekId)) weekMemberPoints.set(weekId, new Map());
    const memberWeek = weekMemberPoints.get(weekId);
    const record = memberWeek.get(memberId) || { official: 0, appearances: 0, appearanceCount: 0, appearanceRates: [] };
    record[kind] += points;
    if (kind === 'appearances') { record.appearanceCount += 1; record.appearanceRates.push(points); }
    memberWeek.set(memberId, record);
  };
  data.scores.forEach((score) => scoresByDance.set(score.dance_id, (scoresByDance.get(score.dance_id) || 0) + score.score));
  data.dances.filter((dance) => dance.kind === 'competitive').forEach((dance) => {
    const pairing = partnershipById.get(dance.partnership_id);
    const score = scoresByDance.get(dance.id) || 0;
    if (pairing) [pairing.star_id, pairing.pro_id].forEach((id) => add(id, dance.week_id, 'official', score));
  });
  data.appearances.forEach((appearance) => {
    const dance = danceById.get(appearance.dance_id);
    const member = memberById.get(appearance.cast_member_id);
    if (dance) add(member?.id, dance.week_id, 'appearances', appearanceValue(member, roleMap, weekById.get(dance.week_id), data.weeks, snapshotByWeekMember.get(`${dance.week_id}:${member?.id}`)));
  });
  return { teams: data.teams, members: data.members, weeks: data.weeks, memberPoints, weekMemberPoints };
}

// Frozen snapshots preserve team and role; appearance counts come from recorded
// dances, while every league uses the current global role rates.
export function scoreLeague(data, context) {
  const teams = data.teams;
  const castById = new Map(data.cast.map((member) => [member.id, member]));
  const pairById = new Map(data.pairs.map((pair) => [pair.id, pair]));
  const weekById = new Map(data.weeks.map((week) => [week.id, week]));
  const danceById = new Map(data.dances.map((dance) => [dance.id, dance]));
  const scoreByDance = new Map();
  const rateByName = new Map(data.roles.map((role) => [role.name, Number(role.appearance_points) || 0]));
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
    const rate = sharedAppearanceRate(cast, snapshot, rateByName);
    add(cast.id, dance.week_id, rate, 'appearances');
  });
  return { totalByTeam, pointsByTeamCast, pointsByWeekTeam, pointsByWeekCast, scoringWeeks, rateByName, scoreByDance, snapshotByKey };
}
