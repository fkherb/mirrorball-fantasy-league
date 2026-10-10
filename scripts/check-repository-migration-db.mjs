// Disposable local PostgreSQL only. Never accepts a live URL or credentials.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
const container = process.argv[2];
assert.match(container || '', /^mirrorball-rename-test-\d{8}$/);
const database = 'mirrorball_repo_rename_tests';
const created = spawnSync('docker', ['exec', container, 'createdb', '-U', 'supabase_admin', database], { encoding: 'utf8' });
if (created.status !== 0) throw Error(created.stderr);
const execute = sql => spawnSync('docker', ['exec', '-i', container, 'psql', '-U', 'supabase_admin',
  '-d', database, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], { input: sql, encoding: 'utf8' });
const query = sql => {
  const result = execute(sql);
  if (result.status !== 0) throw Error(result.stderr);
  return result.stdout.trim();
};
const old = 'https://fkherb.github.io/mirrorball-fantasy-league/';
const renamed = 'https://fkherb.github.io/mirrorball-fantasy/';
const avatars = [old + 'Images/Face%20Photo.png?v=abc#crop',
  'https://example.com/avatar.png?source=' + old,
  'https://fkherb.github.io/mirrorball-fantasy-league-other/face.png',
  null, renamed + 'Images/already-new.png',
  'https://mdrrnanxqazecqviaass.supabase.co/storage/v1/object/public/avatars/face.png'];
query(`create table public.profiles(user_id integer primary key, avatar_url text);
  create table public.fantasy_teams(id integer primary key, avatar_url text);
  insert into public.profiles select (item.ordinality)::integer, item.value #>> '{}'
    from jsonb_array_elements('${JSON.stringify(avatars)}'::jsonb) with ordinality as item(value, ordinality);
  insert into public.fantasy_teams select * from public.profiles;`);
const file = path => readFile(new URL(`../supabase/${path}`, import.meta.url), 'utf8');
const cutover = await file('repo-rename-avatar-cutover.sql');
const rollback = await file('repo-rename-avatar-rollback.sql');
const snapshot = () => query('select jsonb_agg(to_jsonb(p) order by user_id) from public.profiles p;');
const initial = snapshot();
const blocked = execute(cutover);
assert.notEqual(blocked.status, 0);
assert.match(blocked.stderr, /Verify the new website is live/);
assert.equal(snapshot(), initial, 'Guarded cutover must change nothing.');
const ready = cutover.replace("cutover_ready = 'no'", "cutover_ready = 'yes'");
query(ready);
const migrated = JSON.parse(snapshot());
assert.equal(migrated[0].avatar_url, renamed + 'Images/Face%20Photo.png?v=abc#crop');
for (let i = 1; i < avatars.length; i++) assert.equal(migrated[i].avatar_url, avatars[i]);
assert.equal(query('select avatar_url from public.fantasy_teams where id=1;'), migrated[0].avatar_url);
const after = snapshot();
query(ready);
assert.equal(snapshot(), after, 'Cutover is idempotent.');
assert.notEqual(execute(rollback).status, 0);
assert.equal(snapshot(), after, 'Guarded rollback must change nothing.');
const undo = rollback.replace("rollback_ready = 'no'", "rollback_ready = 'yes'");
query(undo);
assert.equal(query('select avatar_url from public.profiles where user_id=1;'), avatars[0]);
assert.equal(query('select avatar_url from public.fantasy_teams where id=1;'), avatars[0]);
const undone = snapshot();
query(undo);
assert.equal(snapshot(), undone, 'Rollback is idempotent.');
query(await file('repo-rename-preflight.sql'));
console.log('PostgreSQL guards, exact-prefix scope, preserved URL suffixes, unrelated/null avatars, idempotency and rollback verified.');
