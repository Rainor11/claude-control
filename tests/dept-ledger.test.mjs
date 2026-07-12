import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
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
