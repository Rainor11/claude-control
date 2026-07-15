import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
const { pickExecutable, newProbeLines, decideSleep, EXEC_KINDS } = createRequire(import.meta.url)('../bin/dept-dispatcher');

test('EXEC_KINDS: только исполняемые диспетчером kind_of', () => {
  assert.deepEqual([...EXEC_KINDS].sort(), ['mission_change', 'planerka', 'sleep', 'worker_spawn']);
});

test('pickExecutable: только исполняемые kind_of И только от руководителя/оператора', () => {
  const roleOf = (n) => ({ 'dept-head': 'руководитель', 'mk-a': 'мк' }[n]);
  const rows = [
    { event_id: 'e1', data: { kind_of: 'worker_spawn', from: 'dept-head' } },
    { event_id: 'e2', data: { kind_of: 'outgoing', from: 'mk-a' } },        // исполняет воркер сам
    { event_id: 'e3', data: { kind_of: 'mission_change', from: 'operator' } },
    { event_id: 'e4', data: { kind_of: 'planerka', from: 'dept-head' } },
    { event_id: 'e5', data: { kind_of: 'kb_change', from: 'dept-archivist' } }, // исполняет архивариус сам
    { event_id: 'e6', data: { kind_of: 'worker_spawn', from: 'mk-a' } },    // МК не может нанимать — отфильтровано
    { event_id: 'e7', data: { kind_of: 'sleep', from: 'dept-head' } },
  ];
  assert.deepEqual(pickExecutable(rows, roleOf).map((r) => r.event_id), ['e1', 'e3', 'e4', 'e7']);
});

test('decideSleep: пороги, гарды, дедуп, авто-режим', () => {
  const cfg = { idleDays: 7 };
  const base = { idleDays: 9, hasOpenApproval: false, hasQueued: false, stale: false, alreadyAsked: false, auto: false };
  assert.equal(decideSleep({ ...base, idleDays: 3 }, cfg), 'none');           // активен
  assert.equal(decideSleep(base, cfg), 'ask_head');                            // предложить руководителю
  assert.equal(decideSleep({ ...base, alreadyAsked: true }, cfg), 'none');     // не спамить
  assert.equal(decideSleep({ ...base, hasQueued: true }, cfg), 'none');        // есть незакрытое — не трогать
  assert.equal(decideSleep({ ...base, hasOpenApproval: true }, cfg), 'none');  // открытый approval — не трогать
  assert.equal(decideSleep({ ...base, stale: true }, cfg), 'none');            // память некурирована
  assert.equal(decideSleep({ ...base, auto: true }, cfg), 'auto_sleep');       // DEPT_SLEEP_AUTO=1
});

test('newProbeLines: маркер ebid и legacy-hash дедупятся против .seen/.dead', () => {
  const seen = new Set(['g:evt_1']);
  const dead = new Set();
  const lines = ['\x1eebid=evt_1\x1e[dept-message] старое', '\x1eebid=evt_2\x1e[dept-message] новое', 'просто строка'];
  const fresh = newProbeLines(lines, seen, dead);
  assert.equal(fresh.length, 2); // evt_2 + legacy-строка
});

test('newProbeLines: legacy sha256-хэш из .seen подавляет строку', () => {
  const h = createHash('sha256').update('просто строка').digest('hex').slice(0, 32);
  assert.equal(newProbeLines(['просто строка'], new Set([h]), new Set()).length, 0);
});

test('newProbeLines: строка в .dead (карантин) тоже подавляется', () => {
  const h = createHash('sha256').update('карантинная строка').digest('hex').slice(0, 32);
  assert.equal(newProbeLines(['карантинная строка'], new Set(), new Set([h])).length, 0);
});

test('newProbeLines: пустые строки игнорируются', () => {
  assert.equal(newProbeLines(['', '   ', 'x'], new Set(), new Set()).length, 1);
});

test('newProbeLines: legacy back-compat — маркированная строка, чей legacy-хэш уже в .seen, подавляется', () => {
  // Codex-аудит В4: доставленное ДО появления stable-id не должно ложно будить контур —
  // тот же дедуп, что делает event-bridge-watch при миграции (записывает g:<id> и не шлёт повторно).
  const visible = '[dept-message] старое до миграции id';
  const legacy = createHash('sha256').update(visible).digest('hex').slice(0, 32);
  const lines = [`\x1eebid=evt_9\x1e${visible}`];
  assert.equal(newProbeLines(lines, new Set([legacy]), new Set()).length, 0);
});
