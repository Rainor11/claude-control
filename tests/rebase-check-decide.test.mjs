// T6: обязательный пролог изоляции (tests/lib/bootstrap.mjs) — первым значимым действием
// файла, до любого импорта bin/*: модули отдела резолвят корень рантайма уже на загрузке.
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { decide, pruneState, staleAlertMessage } = createRequire(import.meta.url)('../bin/dept-rebase-check');

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
test('порог + STALE → stale_alert (STALE — модификатор порога, не «победитель»)', () => {
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

test('STALE без порога → молчим (нечего фиксировать ≠ повод для алерта)', () => {
  // Кейс legion2/prodmash 17.07: сессия 18ч, компакций 0, память старая — триггера НЕТ.
  const r = decide({ ...base, ageMs: 18 * 3600_000, compactions: 0, stale: true }, cfg);
  assert.equal(r.action, 'none');
});

test('STALE + порог возраста → stale_alert (сессия РЕАЛЬНО старая)', () => {
  const r = decide({ ...base, ageMs: 15 * 86400_000, stale: true }, cfg);
  assert.equal(r.action, 'stale_alert');
  assert.match(r.reason, /возраст сессии/);
});

test('STALE + порог компакций → stale_alert с причиной про компакции', () => {
  const r = decide({ ...base, compactions: 4, stale: true }, cfg);
  assert.equal(r.action, 'stale_alert');
  assert.match(r.reason, /компакций/);
});

test('порог + память курируется → rebase (STALE не мешает)', () => {
  const r = decide({ ...base, ageMs: 15 * 86400_000, stale: false }, cfg);
  assert.equal(r.action, 'rebase');
});

test('stale_alert дедуплится alreadyAlerted', () => {
  const r = decide({ ...base, ageMs: 15 * 86400_000, stale: true, alreadyAlerted: true }, cfg);
  assert.equal(r.action, 'none');
});

test('ENFORCE не превращает stale_alert в rebase (курируемая память — инвариант)', () => {
  const r = decide({ ...base, ageMs: 15 * 86400_000, stale: true, enforce: true }, cfg);
  assert.equal(r.action, 'stale_alert');
});

test('свежая сессия без порогов и без stale → none', () => {
  assert.equal(decide({ ...base }, cfg).action, 'none');
});

test('после докурации памяти дедуп не глушит [would-rebase] (переход фазы)', () => {
  // Эпизод: сессия старая + память STALE → stale_alert (фаза stale_alerted). Воркер
  // докурировал → stale=false, порог возраста остался. alreadyAlerted теперь считается по
  // ФАЗЕ rebase_alerted, которой ещё не было → decide обязан вернуть rebase, а не none.
  const r = decide({ ...base, ageMs: 15 * 86400_000, stale: false, alreadyAlerted: false }, cfg);
  assert.equal(r.action, 'rebase', 'после курации воркер обязан получить [would-rebase], а не застрять молча');
});

test('stale_alert с alreadyAlerted не повторяется — просьба о курации уйдёт один раз за эпизод', () => {
  // Гарантия анти-спама: ветка отправки просьбы живёт ВНУТРИ d.action==='stale_alert',
  // а он гасится alreadyAlerted. Эпизод сбрасывается только при уходе триггера (anyTrigger=false).
  const first = decide({ ...base, ageMs: 15 * 86400_000, stale: true, alreadyAlerted: false }, cfg);
  const second = decide({ ...base, ageMs: 15 * 86400_000, stale: true, alreadyAlerted: true }, cfg);
  assert.equal(first.action, 'stale_alert');
  assert.equal(second.action, 'none');
});

// M1: dry-превью не должно врать про доставку (bus в dry всегда false, т.к. ветка
// отправки по шине целиком пропускается — не путать с реальным сбоем).
test('staleAlertMessage: dry — честная формулировка, без 🔴-маркера ошибки', () => {
  const msg = staleAlertMessage({ dry: true, bus: false, name: 'w1', reason: 'возраст сессии ≥ 14 дн' });
  assert.match(msg, /\[dry\]/);
  assert.doesNotMatch(msg, /🔴/);
  assert.doesNotMatch(msg, /НЕ отправлена/);
});
test('staleAlertMessage: боевой прогон, доставка удалась — «отправлена»', () => {
  const msg = staleAlertMessage({ dry: false, bus: true, name: 'w1', reason: 'возраст сессии ≥ 14 дн' });
  assert.match(msg, /воркеру отправлена просьба/);
  assert.doesNotMatch(msg, /🔴/);
});
test('staleAlertMessage: боевой прогон, доставка провалилась — 🔴 НЕ отправлена (поведение не менялось)', () => {
  const msg = staleAlertMessage({ dry: false, bus: false, name: 'w1', reason: 'возраст сессии ≥ 14 дн' });
  assert.match(msg, /🔴 НЕ отправлена/);
});
