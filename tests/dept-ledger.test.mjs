import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, utimesSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CLI = new URL('../bin/dept-ledger', import.meta.url).pathname;
const run = (home, args, input) =>
  execFileSync(CLI, args, { env: { ...process.env, DEPT_HOME: home }, input, encoding: 'utf8' });

test('append пишет конверт и монотонный seq', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['append', '--kind', 'incident', '--actor', 'watchdog',
    '--data', '{"about_worker":"x","severity":"high","summary":"hung"}']));
  const b = JSON.parse(run(home, ['append', '--kind', 'incident', '--actor', 'watchdog',
    '--data', '{"about_worker":"y","severity":"low","summary":"slow"}']));
  assert.match(a.event_id, /^evt_\d+_[a-z0-9]{4}$/);
  assert.equal(b.seq, a.seq + 1);
  const lines = readFileSync(join(home, 'events.jsonl'), 'utf8').trim().split('\n');
  assert.equal(lines.length, 2);
  const env0 = JSON.parse(lines[0]);
  assert.equal(env0.kind, 'incident');
  assert.equal(env0.actor, 'watchdog');
  assert.equal(env0.data.severity, 'high');
});

test('append отклоняет неизвестный kind и битый json', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['append', '--kind', 'nonsense', '--data', '{}']));
  assert.throws(() => run(home, ['append', '--kind', 'incident', '--data', '{broken']));
});

test('list фильтрует по kind и полям data', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'incident', '--data', '{"about_worker":"x","severity":"high","summary":"s1"}']);
  run(home, ['append', '--kind', 'agent_run', '--data', '{"worker":"x","run_kind":"wake"}']);
  const out = run(home, ['list', '--kind', 'incident', '--filter', 'about_worker=x']);
  const rows = out.trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].data.summary, 's1');
});

test('протухший лок не блокирует запись', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const lock = join(home, 'events.jsonl.lock');
  writeFileSync(lock, '999999');
  const past = new Date(Date.now() - 120000); // 2 минуты назад — старше порога протухания (60с)
  utimesSync(lock, past, past);
  const env = JSON.parse(run(home, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"x","severity":"high","summary":"stale-lock"}']));
  assert.equal(env.seq, 1);
});

test('битая строка в журнале пропускается, seq продолжается', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"x","severity":"high","summary":"first"}']);
  appendFileSync(join(home, 'events.jsonl'), '{broken\n');
  const res = spawnSync(CLI, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"y","severity":"low","summary":"second"}'],
    { env: { ...process.env, DEPT_HOME: home }, encoding: 'utf8' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  const env = JSON.parse(res.stdout);
  assert.equal(env.seq, 2);
  assert.match(res.stderr, /битая строка/);
  const rows = run(home, ['list', '--kind', 'incident']).trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 2);
});

test('*_status с несуществующим ref отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['append', '--kind', 'message_status',
    '--data', '{"ref":"evt_0_none","status":"acked"}']));
});

test('--data null отклоняется чисто', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(
    () => run(home, ['append', '--kind', 'incident', '--data', 'null']),
    (err) => {
      assert.ok(!String(err.stderr).includes('TypeError'), `stderr: ${err.stderr}`);
      return true;
    }
  );
});
