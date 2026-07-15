import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { decide, pruneState } = createRequire(import.meta.url)('../bin/dept-rebase-check');

const cfg = { maxAgeDays: 14, maxCompactions: 3 };
const now = Date.now();
const base = { ageMs: 0, compactions: 0, stale: false, alreadyAlerted: false };

test('молодая сессия без компакций — none', () => {
  assert.equal(decide({ ...base }, cfg).action, 'none');
});
test('возраст за порогом — rebase c причиной-возрастом', () => {
  const d = decide({ ...base, ageMs: 15 * 86400_000 }, cfg);
  assert.equal(d.action, 'rebase');
  assert.match(d.reason, /возраст/);
});
test('компакции за порогом — rebase', () => {
  const d = decide({ ...base, compactions: 3 }, cfg);
  assert.equal(d.action, 'rebase');
  assert.match(d.reason, /компакц/);
});
test('STALE побеждает: только stale_alert, даже при возрасте за порогом', () => {
  const d = decide({ ...base, ageMs: 20 * 86400_000, stale: true }, cfg);
  assert.equal(d.action, 'stale_alert');
});
test('уже алертили этот эпизод — none (не спамить)', () => {
  assert.equal(decide({ ...base, ageMs: 20 * 86400_000, alreadyAlerted: true, enforce: false }, cfg).action, 'none');
});

test('pruneState: уход из active закрывает эпизод — запись выпадает', () => {
  const state = { w1: { alerted: true } };
  const dept = { w1: { role: 'мк' } };
  const auto = { w1: { state: 'sleeping' } };
  pruneState(state, dept, auto);
  assert.equal('w1' in state, false);
});
test('pruneState: active воркер с ролью отдела остаётся', () => {
  const state = { w1: { alerted: true }, gone: { alerted: true }, legacy: { alerted: true } };
  const dept = { w1: { role: 'руководитель' }, legacy: { role: 'legacy' } };
  const auto = { w1: { state: 'active' }, legacy: { state: 'active' } };
  pruneState(state, dept, auto);
  assert.deepEqual(state, { w1: { alerted: true } }); // gone (нет в реестре) и legacy (не-отдельная роль) выпали
});
