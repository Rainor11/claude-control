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

test('anim_alert: экран меняется, транскрипт стоит дольше animMin', () => {
  const cfg = { hungMin: 30, reincidentMin: 60, animMin: 90 };
  const now = Date.now();
  const prev = { screenHash: 'aaa', firstSeen: now - 10 * 60_000, alerted: false, restartedAt: 0 };
  const cur = { ts: now, busy: true, screenHash: 'bbb', transcriptMtime: now - 100 * 60_000 };
  assert.deepEqual(decide(prev, cur, cfg).action, 'anim_alert');
});

test('anim_alert: не повторяется в том же эпизоде', () => {
  const cfg = { hungMin: 30, reincidentMin: 60, animMin: 90 };
  const now = Date.now();
  const prev = { screenHash: 'aaa', firstSeen: now, alerted: false, restartedAt: 0, animAlerted: true };
  const cur = { ts: now, busy: true, screenHash: 'bbb', transcriptMtime: now - 100 * 60_000 };
  assert.equal(decide(prev, cur, cfg).action, 'none');
});

test('anim-сигнал не мешает основной лестнице: замерший экран идёт по старому пути', () => {
  const cfg = { hungMin: 30, reincidentMin: 60, animMin: 90 };
  const now = Date.now();
  const prev = { screenHash: 'aaa', firstSeen: now - 31 * 60_000, alerted: false, restartedAt: 0 };
  const cur = { ts: now, busy: true, screenHash: 'aaa', transcriptMtime: now - 100 * 60_000 };
  assert.equal(decide(prev, cur, cfg).action, 'alert');
});

test('anim-эпизод сбрасывается при свежем транскрипте', () => {
  const cfg = { hungMin: 30, reincidentMin: 60, animMin: 90 };
  const now = Date.now();
  const prev = { screenHash: 'aaa', firstSeen: now, alerted: false, restartedAt: 0, animAlerted: true };
  const cur = { ts: now, busy: true, screenHash: 'bbb', transcriptMtime: now - 60_000 };
  const d = decide(prev, cur, cfg);
  assert.equal(d.action, 'none');
  assert.equal(d.reset, true); // reset очищает animAlerted
});

test('anim-эпизод переходит в основную лестницу, когда экран замирает', () => {
  const cfg = { hungMin: 30, reincidentMin: 60, animMin: 90 };
  const now = Date.now();
  // main-loop уже продвинул screenHash до текущего кадра; экран замер на нём
  const prev = { screenHash: 'frozen', firstSeen: now - 120 * 60_000, alerted: false, restartedAt: 0, animAlerted: true };
  const cur = { ts: now, busy: true, screenHash: 'frozen', transcriptMtime: now - 130 * 60_000 };
  assert.equal(decide(prev, cur, cfg).action, 'alert'); // основная лестница ожила
});
