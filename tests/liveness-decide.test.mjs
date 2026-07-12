import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { decide } = createRequire(import.meta.url)('../bin/claude-auto-liveness');

const cfg = { hungMin: 15, reincidentMin: 60 };
const now = 10_000_000_000;
const cur = (over = {}) => ({
  ts: now, busy: true, screenHash: 'aaa', transcriptMtime: now - 20 * 60_000, ...over,
});

test('idle с замершим экраном — не hung', () => {
  const a = decide(null, cur({ busy: false }), cfg);
  assert.equal(a.action, 'none');
});

test('busy + свежий транскрипт — работает, не hung', () => {
  const a = decide(null, cur({ transcriptMtime: now - 60_000 }), cfg);
  assert.equal(a.action, 'none');
});

test('первое подтверждение hung — alert', () => {
  const prev = { screenHash: 'aaa', firstSeen: now - 16 * 60_000, alerted: false, restartedAt: 0 };
  const a = decide(prev, cur(), cfg);
  assert.equal(a.action, 'alert');
});

test('второе подряд — restart', () => {
  const prev = { screenHash: 'aaa', firstSeen: now - 30 * 60_000, alerted: true, restartedAt: 0 };
  const a = decide(prev, cur(), cfg);
  assert.equal(a.action, 'restart');
});

test('hung после недавнего рестарта — incident', () => {
  const prev = { screenHash: 'aaa', firstSeen: now - 16 * 60_000, alerted: true, restartedAt: now - 30 * 60_000 };
  const a = decide(prev, cur(), cfg);
  assert.equal(a.action, 'incident');
});

test('экран изменился — сброс наблюдения', () => {
  const prev = { screenHash: 'bbb', firstSeen: now - 30 * 60_000, alerted: true, restartedAt: 0 };
  const a = decide(prev, cur(), cfg);
  assert.equal(a.action, 'none');
  assert.equal(a.reset, true);
});
