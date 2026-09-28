import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { episodeSpotlight, standingsSwitch, standingCard, overviewTeamDetail, danceCard } from '../postdraft-view.js';

const week = { id: 'week-6', number: 6, title: 'Disney Night' };
const upcoming = episodeSpotlight({ week, state: 'upcoming', performances: 12, scored: 0 });
assert.match(upcoming, /Coming up · Week 6/);
assert.match(upcoming, /Explore the episode/);
assert.match(upcoming, /aria-valuemax="12" aria-valuenow="0"/);
assert.doesNotMatch(upcoming, /LIVE/);

const receiving = episodeSpotlight({ week, state: 'receiving', performances: 12, scored: 4 });
assert.match(receiving, /Scores being entered/);
assert.match(receiving, /Fantasy standings update when the week is finalized/);

const complete = episodeSpotlight({ week, state: 'complete', teamPoints: 71, portrait: 'Images/Test.jpg' });
assert.match(complete, /Results are in/);
assert.match(complete, /Your team this week/);
assert.match(complete, /Images\/Test.jpg/);

assert.match(standingsSwitch('week', week), /data-standings-mode="week" aria-pressed="true"/);
const card = standingCard({ id: 'team-1', rank: 1, manager: 'Freddy', name: 'Team Ferb', total: 181,
  contributors: [{ name: 'Daniella', points: 29 }], weekPoints: 71, movement: 2 });
assert.match(card, /\+71 latest week/);
assert.match(card, /2 places gained/);
assert.match(card, /season points/);
assert.match(overviewTeamDetail({ name: 'Team Ferb', manager: 'Freddy', total: 71, castRows: [], period: 'week' }), /this week/);

const dance = danceCard({ id: 'dance-1', kind: 'competitive', title: 'Pair', danceType: 'Samba', song: '',
  scores: [{ judge_name: 'Carrie Ann', score: 9 }, { judge_name: 'Derek', score: 10 }], castNames: [], scoreImage: (score) => `${score}.png` });
assert.match(dance, /Judges total 19/);

const experienceStyles = await readFile(new URL('../research-experience.css', import.meta.url), 'utf8');
assert.match(experienceStyles, /\.card\s*\{[^}]*background:\s*var\(--experience-surface\)/);
assert.match(experienceStyles, /#signin\s+\.signin-card\s*\{[^}]*background:\s*linear-gradient\(/);

console.log('Research-led experience components verified.');
