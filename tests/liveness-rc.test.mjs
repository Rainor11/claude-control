// T6: обязательный пролог изоляции (tests/lib/bootstrap.mjs) — первым значимым действием
// файла, до любого импорта bin/*: модули отдела резолвят корень рантайма уже на загрузке.
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { rcSignal, rcEpisode, rcAllowRestart } = createRequire(import.meta.url)('../bin/claude-auto-liveness');

// --- rcSignal(screen) — классификация RC-состояния по футеру TUI --------------------------
// Маркер '/rc' живёт в chrome-зоне ПОД последним горизонтальным бордером (нижняя граница
// поля ввода); варианты '/rc active|connecting|reconnecting|failed' зашиты в CLI.
// Экраны ниже — по реальным capture-pane воркеров (широкая и узкая панель).

const SEP = '─'.repeat(40);
const STATUS = '  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent';

function scr({ convo = 'обычный текст разговора', input = '❯ ', chrome = [STATUS] } = {}) {
  return [convo, SEP, input, SEP, ...chrome, ''].join('\n');
}

test('rcSignal: пустой капчер → unknown', () => {
  assert.equal(rcSignal(null), 'unknown');
  assert.equal(rcSignal(undefined), 'unknown');
});

test('rcSignal: маркер в конце статусной строки (широкая панель) → ok', () => {
  assert.equal(rcSignal(scr({ chrome: [`${STATUS}                     /rc`] })), 'ok');
});

test('rcSignal: маркер на отдельной строке (узкая панель, wrap) → ok', () => {
  assert.equal(rcSignal(scr({ chrome: [STATUS, '  new task? /clear to save 300k tokens', '        /rc'] })), 'ok');
});

test('rcSignal: /rc active → ok', () => {
  assert.equal(rcSignal(scr({ chrome: [`${STATUS}    /rc active`] })), 'ok');
});

test('rcSignal: connecting/reconnecting → transient', () => {
  assert.equal(rcSignal(scr({ chrome: [`${STATUS}    /rc connecting`] })), 'transient');
  assert.equal(rcSignal(scr({ chrome: [STATUS, '  /rc reconnecting'] })), 'transient');
});

test('rcSignal: /rc failed → failed', () => {
  assert.equal(rcSignal(scr({ chrome: [STATUS, '  /rc failed'] })), 'failed');
});

test('rcSignal: chrome есть, маркера нет → absent (главный симптом обрыва)', () => {
  assert.equal(rcSignal(scr({ chrome: [STATUS, '  new task? /clear to save 300k tokens'] })), 'absent');
});

test('rcSignal: цитата «/rc failed» в разговоре НЕ считается — маркер судится только в chrome-зоне', () => {
  // цитата выше бордера; настоящий футер здоров
  assert.equal(rcSignal(scr({ convo: 'воркер обсуждает инцидент: «/rc failed» на экране',
    chrome: [`${STATUS}   /rc`] })), 'ok');
  // цитата выше бордера; футер без маркера — absent, НЕ failed
  assert.equal(rcSignal(scr({ convo: 'в логе было /rc failed',
    chrome: [STATUS] })), 'absent');
});

test('rcSignal: busy-хвост (идёт ход) → skip, не наблюдение', () => {
  assert.equal(rcSignal(scr({ chrome: [STATUS, '  126 tokens · esc to interrupt'] })), 'skip');
});

test('rcSignal: approval-промпт → skip', () => {
  assert.equal(rcSignal(scr({ input: '  Do you want to proceed?', chrome: [STATUS] })), 'skip');
});

test('rcSignal: экран без бордера (структура не распознана) → unknown', () => {
  assert.equal(rcSignal('какой-то текст\nбез разделителей\n'), 'unknown');
});

test('rcSignal: бордер есть, но zone пустая → unknown', () => {
  assert.equal(rcSignal(`текст\n${SEP}\n\n\n`), 'unknown');
});

// --- rcEpisode(prev, obs, now, cfg) — time-based эпизод обрыва ----------------------------

const CFG = { rcAbsentMin: 15, rcTransientMin: 25, rcGapMin: 15, rcMaxRestarts: 2, rcWindowH: 24 };
const MIN = 60_000;
const T0 = 1_700_000_000_000;
const ob = (name, signal, sessionCreated = 111) => ({ name, signal, sessionCreated });

test('rcEpisode: первое плохое наблюдение создаёт member, due пуст', () => {
  const { members, due } = rcEpisode(null, [ob('w', 'absent')], T0, CFG);
  assert.deepEqual(due, []);
  assert.equal(members.w.obsCount, 1);
  assert.equal(members.w.firstBadAt, T0);
  assert.equal(members.w.badKind, 'absent');
});

test('rcEpisode: ok сбрасывает эпизод (member не переносится)', () => {
  const prev = { members: { w: { firstBadAt: T0, badKind: 'absent', obsCount: 2, lastObservedAt: T0 + 5 * MIN, sessionCreated: 111 } } };
  const { members, due } = rcEpisode(prev, [ob('w', 'ok')], T0 + 10 * MIN, CFG);
  assert.deepEqual(due, []);
  assert.equal(members.w, undefined);
});

test('rcEpisode: absent — 3 наблюдения, но рано по времени → не due; по прошествии rcAbsentMin → due', () => {
  let ep = rcEpisode(null, [ob('w', 'absent')], T0, CFG);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'absent')], T0 + 5 * MIN, CFG);
  assert.deepEqual(ep.due, []);
  // 3-е наблюдение на 10-й минуте: obsCount=3, но elapsed 10 < 15 → рано
  ep = rcEpisode({ members: ep.members }, [ob('w', 'absent')], T0 + 10 * MIN, CFG);
  assert.deepEqual(ep.due, []);
  assert.equal(ep.members.w.obsCount, 3);
  // 4-е на 15-й: порог времени взят
  ep = rcEpisode({ members: ep.members }, [ob('w', 'absent')], T0 + 15 * MIN, CFG);
  assert.deepEqual(ep.due, ['w']);
});

test('rcEpisode: failed подтверждается быстрее — 2 наблюдения ПОДРЯД', () => {
  let ep = rcEpisode(null, [ob('w', 'failed')], T0, CFG);
  assert.deepEqual(ep.due, []);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'failed')], T0 + 5 * MIN, CFG);
  assert.deepEqual(ep.due, ['w']);
});

test('rcEpisode: смешанная серия absent→failed НЕ минует пороги (fast-path только для failed подряд)', () => {
  let ep = rcEpisode(null, [ob('w', 'absent')], T0, CFG);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'absent')], T0 + 5 * MIN, CFG);
  // первый failed после absent'ов: obsCount=3, но предыдущий вид не failed → рано
  ep = rcEpisode({ members: ep.members }, [ob('w', 'failed')], T0 + 10 * MIN, CFG);
  assert.deepEqual(ep.due, []);
  // второй failed подряд → due
  ep = rcEpisode({ members: ep.members }, [ob('w', 'failed')], T0 + 12 * MIN, CFG);
  assert.deepEqual(ep.due, ['w']);
});

test('rcEpisode: имя воркера __proto__ не ломает members (prototype pollution)', () => {
  const { members } = rcEpisode(null, [ob('__proto__', 'absent')], T0, CFG);
  assert.equal(members['__proto__'].obsCount, 1);
  assert.equal(JSON.parse(JSON.stringify({ m: members })).m['__proto__'].obsCount, 1);
});

test('rcEpisode: transient — дольше absent (не сбивать штатный reconnect-backoff)', () => {
  let ep = rcEpisode(null, [ob('w', 'transient')], T0, CFG);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'transient')], T0 + 10 * MIN, CFG);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'transient')], T0 + 20 * MIN, CFG);
  assert.deepEqual(ep.due, []); // 20 < 25
  ep = rcEpisode({ members: ep.members }, [ob('w', 'transient')], T0 + 26 * MIN, CFG);
  assert.deepEqual(ep.due, ['w']);
});

test('rcEpisode: skip/unknown замораживают эпизод — не двигают и не рвут', () => {
  let ep = rcEpisode(null, [ob('w', 'absent')], T0, CFG);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'skip')], T0 + 5 * MIN, CFG);
  assert.equal(ep.members.w.obsCount, 1);
  assert.equal(ep.members.w.lastObservedAt, T0);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'unknown')], T0 + 10 * MIN, CFG);
  assert.equal(ep.members.w.obsCount, 1);
});

test('rcEpisode: разрыв наблюдений > rcGapMin рвёт streak (заморозка skip → потом bad = новый эпизод)', () => {
  let ep = rcEpisode(null, [ob('w', 'absent')], T0, CFG);
  // час busy-skip'ов — эпизод заморожен, lastObservedAt остался T0
  ep = rcEpisode({ members: ep.members }, [ob('w', 'skip')], T0 + 60 * MIN, CFG);
  // плохое наблюдение после разрыва 61 мин > 15 → НОВЫЙ эпизод, а не «второе подряд»
  ep = rcEpisode({ members: ep.members }, [ob('w', 'absent')], T0 + 61 * MIN, CFG);
  assert.equal(ep.members.w.obsCount, 1);
  assert.equal(ep.members.w.firstBadAt, T0 + 61 * MIN);
});

test('rcEpisode: смена sessionCreated (воркер пересоздан) сбрасывает эпизод', () => {
  let ep = rcEpisode(null, [ob('w', 'absent', 111)], T0, CFG);
  ep = rcEpisode({ members: ep.members }, [ob('w', 'absent', 222)], T0 + 5 * MIN, CFG);
  assert.equal(ep.members.w.obsCount, 1);
  assert.equal(ep.members.w.sessionCreated, 222);
});

test('rcEpisode: воркер пропал из наблюдений → выбывает из members', () => {
  const prev = { members: { gone: { firstBadAt: T0, badKind: 'absent', obsCount: 2, lastObservedAt: T0, sessionCreated: 1 } } };
  const { members } = rcEpisode(prev, [ob('other', 'ok')], T0 + 5 * MIN, CFG);
  assert.equal(members.gone, undefined);
});

test('rcEpisode: битый prev (файл правили руками) деградирует в пустой эпизод, не бросает', () => {
  for (const bad of [{ members: 'мусор' }, { members: 42 }, 'строка', 7]) {
    const { members, due } = rcEpisode(bad, [ob('w', 'absent')], T0, CFG);
    assert.deepEqual(due, []);
    assert.equal(members.w.obsCount, 1);
  }
});

test('rcEpisode: битый member (NaN в числовых полях) деградирует в НОВЫЙ эпизод, а не глушит пороги навсегда', () => {
  const prev = { members: { w: { firstBadAt: NaN, badKind: 'absent', obsCount: NaN, lastObservedAt: NaN, sessionCreated: 111 } } };
  const { members, due } = rcEpisode(prev, [ob('w', 'absent')], T0, CFG);
  assert.deepEqual(due, []);
  assert.equal(members.w.obsCount, 1);
  assert.equal(members.w.firstBadAt, T0);
});

// --- rcAllowRestart(history, now, cfg) — cap авто-рестартов -------------------------------

test('rcAllowRestart: пустая/битая история → разрешено', () => {
  assert.equal(rcAllowRestart(undefined, T0, CFG).allowed, true);
  assert.equal(rcAllowRestart('мусор', T0, CFG).allowed, true);
  assert.equal(rcAllowRestart([], T0, CFG).allowed, true);
});

test('rcAllowRestart: cap 2/24ч — два свежих рестарта закрывают лимит', () => {
  const h = [T0 - 60 * MIN, T0 - 30 * MIN];
  const r = rcAllowRestart(h, T0, CFG);
  assert.equal(r.allowed, false);
  assert.deepEqual(r.fresh, h);
});

test('rcAllowRestart: просроченные записи выпадают из окна — лимит освобождается', () => {
  const r = rcAllowRestart([T0 - 25 * 3_600_000, T0 - 30 * MIN], T0, CFG);
  assert.equal(r.allowed, true);
  assert.deepEqual(r.fresh, [T0 - 30 * MIN]);
});

test('rcAllowRestart: мусор и будущие timestamps (clock rollback) отфильтровываются', () => {
  const r = rcAllowRestart(['x', NaN, null, T0 + 60 * MIN, T0 - 10 * MIN], T0, CFG);
  assert.deepEqual(r.fresh, [T0 - 10 * MIN]);
  assert.equal(r.allowed, true);
});

// --- история #rc переживает выздоровление эпизода (cap не обнуляется) ---------------------
// Санитария state[RC_KEY] в main-блоке хранит history НЕЗАВИСИМО от members; здесь
// проверяем контрактную комбинацию чистых функций: ok-выздоровление чистит member,
// но history, переданная в rcAllowRestart на СЛЕДУЮЩЕМ обрыве, всё ещё считает лимит.
test('контракт: выздоровление не возвращает потраченные рестарты', () => {
  const ep1 = rcEpisode({ members: { w: { firstBadAt: T0, badKind: 'absent', obsCount: 3, lastObservedAt: T0, sessionCreated: 1 } } },
    [ob('w', 'ok')], T0 + 5 * MIN, CFG);
  assert.equal(ep1.members.w, undefined);
  const history = [T0 - 60 * MIN, T0 - 30 * MIN]; // живёт отдельно от members
  assert.equal(rcAllowRestart(history, T0 + 10 * MIN, CFG).allowed, false);
});
