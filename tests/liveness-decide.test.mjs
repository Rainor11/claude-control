import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { decide, nextState } = createRequire(import.meta.url)('../bin/claude-auto-liveness');

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

// --- nextState(prev, cur, action, notifyOk) — чистая запись state[name] по веткам ---
// T1 п.1/п.2 плана: anim_alert пишет свежий hash; смена экрана сбрасывает alerted/
// wouldNotified/wouldIncidentNotified (старый алерт был про предыдущее замершее состояние);
// no-op основной лестницы (hash равен) эти флаги НЕ трогает — иначе дедуп alert→restart сломан.

test('nextState anim_alert: пишет СВЕЖИЙ hash (не старый prev.screenHash)', () => {
  const prev = { screenHash: 'old', firstSeen: 1000, alerted: false, restartedAt: 0 };
  const cur = { ts: 2000, screenHash: 'new', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'anim_alert', true);
  assert.equal(s.screenHash, 'new');
});

test('nextState anim_alert: сбрасывает alerted/wouldNotified/wouldIncidentNotified безусловно (экран сменился by construction)', () => {
  const prev = { screenHash: 'old', firstSeen: 1000, alerted: true, restartedAt: 0, wouldNotified: true, wouldIncidentNotified: true };
  const cur = { ts: 2000, screenHash: 'new', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'anim_alert', true);
  assert.equal(s.alerted, false);
  assert.equal(s.wouldNotified, false);
  assert.equal(s.wouldIncidentNotified, false);
});

test('nextState anim_alert: сбрасывает даже если сам notify этого тика провалился (animOk=false)', () => {
  const prev = { screenHash: 'old', firstSeen: 1000, alerted: true, restartedAt: 0 };
  const cur = { ts: 2000, screenHash: 'new', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'anim_alert', false);
  assert.equal(s.animAlerted, false); // дедуп anim-эпизода — по факту доставки этого алерта
  assert.equal(s.alerted, false); // но сброс "устаревшего" alerted не зависит от notifyOk
});

test('nextState none: экран СМЕНИЛСЯ (anim-эпизод продолжается) — сбрасывает alerted/wouldNotified', () => {
  const prev = { screenHash: 'aaa', firstSeen: 1000, alerted: true, restartedAt: 0, wouldNotified: true, animAlerted: true };
  const cur = { ts: 2000, screenHash: 'bbb', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'none');
  assert.equal(s.screenHash, 'bbb');
  assert.equal(s.alerted, false);
  assert.equal(s.wouldNotified, false);
});

test('nextState none: hash РАВЕН (no-op основной лестницы) — alerted/wouldNotified НЕ трогает', () => {
  const prev = { screenHash: 'aaa', firstSeen: 1000, alerted: true, restartedAt: 0, wouldNotified: true };
  const cur = { ts: 2000, screenHash: 'aaa', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'none');
  assert.equal(s.screenHash, 'aaa');
  assert.equal(s.alerted, true); // дедуп лестницы жив — не сброшен из-за no-op
  assert.equal(s.wouldNotified, true);
});

test('nextState alert: успешный notify выставляет alerted:true поверх prev', () => {
  const prev = { screenHash: 'aaa', firstSeen: 1000, alerted: false, restartedAt: 0 };
  const cur = { ts: 2000, screenHash: 'aaa', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'alert', true);
  assert.equal(s.alerted, true);
});

test('nextState alert: провал notify оставляет prev как есть (повтор на следующем тике)', () => {
  const prev = { screenHash: 'aaa', firstSeen: 1000, alerted: false, restartedAt: 0 };
  const cur = { ts: 2000, screenHash: 'aaa', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'alert', false);
  assert.equal(s, prev); // тот же объект — ничего не изменилось
});

test('nextState reset: свежий эпизод с alerted:false, restartedAt наследуется из prev', () => {
  const prev = { screenHash: 'aaa', firstSeen: 1000, alerted: true, restartedAt: 777 };
  const cur = { ts: 2000, screenHash: 'bbb', transcriptMtime: 500 };
  const s = nextState(prev, cur, 'reset');
  assert.equal(s.screenHash, 'bbb');
  assert.equal(s.firstSeen, 2000);
  assert.equal(s.alerted, false);
  assert.equal(s.restartedAt, 777);
});
