// T6: обязательный пролог изоляции (tests/lib/bootstrap.mjs) — первым значимым действием
// файла, до любого импорта bin/*: модули отдела резолвят корень рантайма уже на загрузке.
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const { authVerdict, authSignal, authVerdictFromFile, authEpisode, authNotified } = createRequire(import.meta.url)('../bin/claude-auto-liveness');

// --- authVerdict(tail) — машинный факт «логин протух» из хвоста транскрипта ---------------
// Экранный маркер сам по себе доказательством не является (воркер мог процитировать текст
// ошибки, строка могла остаться в скроллбеке после восстановления). Источник истины —
// синтетическая запись транскрипта: {type:"assistant", isApiErrorMessage:true,
// message.content[].text = "Login expired · Please run /login"} — формат подтверждён по
// реальному инциденту 21.07 (~/.claude/projects/*/<session_id>.jsonl).
//
// «Последняя запись = ошибка» — СЛИШКОМ строго: после неё ложатся user-записи от инжектов
// event-bridge. Поэтому идём с конца и сравниваем, что встретилось раньше — auth-ошибка
// (значит логин всё ещё мёртв) или успешный ответ ассистента (значит воркер уже ожил).

const authError = (text = 'Login expired · Please run /login') => JSON.stringify({
  type: 'assistant',
  isApiErrorMessage: true,
  message: { model: '<synthetic>', role: 'assistant', content: [{ type: 'text', text }] },
});
const okAssistant = (text = 'Готово, задачу закрыл.') => JSON.stringify({
  type: 'assistant',
  message: { model: 'claude-opus-4-8', role: 'assistant', content: [{ type: 'text', text }] },
});
const userTurn = (text = '[event-bridge | source=asana] новое событие') => JSON.stringify({
  type: 'user',
  message: { role: 'user', content: [{ type: 'text', text }] },
});

test('authVerdict: auth-ошибка последней записью — unresolved', () => {
  const tail = [okAssistant(), authError()].join('\n');
  assert.equal(authVerdict(tail), 'unresolved');
});

test('authVerdict: успешный ответ ПОСЛЕ ошибки — resolved (воркер ожил)', () => {
  const tail = [authError(), okAssistant()].join('\n');
  assert.equal(authVerdict(tail), 'resolved');
});

test('authVerdict: воркер ЦИТИРУЕТ текст ошибки в живом ответе — resolved, не unresolved', () => {
  // Ровно этот ложняк ждёт воркеров отдела, обсуждающих сам инцидент 21.07: текст ошибки
  // в обычном ответе ассистента (без isApiErrorMessage) — не доказательство протухшего логина.
  const tail = [okAssistant('Разобрал инцидент: на экранах висело "Login expired · Please run /login".')].join('\n');
  assert.equal(authVerdict(tail), 'resolved');
});

test('authVerdict: не-auth API-ошибка поверх auth-ошибки — всё ещё unresolved', () => {
  // Сетевой флап (500) не означает ни выздоровления, ни протухшего логина — пропускаем
  // такую запись и продолжаем искать настоящее доказательство глубже.
  const apiError500 = JSON.stringify({
    type: 'assistant', isApiErrorMessage: true,
    message: { model: '<synthetic>', role: 'assistant', content: [{ type: 'text', text: 'API Error: 500 Internal Server Error' }] },
  });
  const tail = [authError(), apiError500].join('\n');
  assert.equal(authVerdict(tail), 'unresolved');
});

test('authVerdict: user-записи от инжектов после ошибки не считаются оживанием', () => {
  // Главная причина, по которой «последняя запись = ошибка» не годится: event-bridge
  // продолжает инжектить события, и каждый инжект кладёт user-запись ПОВЕРХ ошибки.
  const tail = [authError(), userTurn(), userTurn('[dept-message type=handoff]')].join('\n');
  assert.equal(authVerdict(tail), 'unresolved');
});

test('authVerdict: обрезанная первая строка окна не ломает разбор', () => {
  // Хвост режется по байтам, не по строкам — первая строка окна почти всегда битая.
  const tail = ['ent":[{"type":"text","text":"хвост обрезан"}]}}', authError()].join('\n');
  assert.equal(authVerdict(tail), 'unresolved');
});

test('authVerdict: в окне нет ни ошибки, ни ответа — unknown, а не выздоровление', () => {
  assert.equal(authVerdict([userTurn(), userTurn()].join('\n')), 'unknown');
  assert.equal(authVerdict(''), 'unknown');
});

// --- authSignal(screen, verdict) — два ключа: экран + машинный вердикт транскрипта --------
// blocked требует ОБА: маркер на экране и подтверждение из транскрипта. Экран один даёт
// ложняки (цитата, скроллбек), транскрипт один — не отличает «мёртв» от «читаем не тот файл».
// busy считается по ХВОСТУ экрана, не по всему pane: остаточный `esc to interrupt` в истории
// иначе маскирует auth-состояние (весь pane — то, как это делает основная лестница decide()).

const deadScreen = [
  '⏺ Login expired · Please run /login',
  '',
  '─────────────────────────────────── dept-archivist ──',
  '❯ ',
  '──────────────────────────────────────────────────────',
  '  ⏵⏵ auto mode on (shift+tab to cycle)',
].join('\n');

test('authSignal: маркер на экране + unresolved из транскрипта — blocked', () => {
  assert.equal(authSignal(deadScreen, 'unresolved'), 'blocked');
});

test('authSignal: транскрипт не прочитан — unknown, а не clear (сбой ≠ выздоровление)', () => {
  assert.equal(authSignal(deadScreen, 'unknown'), 'unknown');
});

test('authSignal: идёт ход (busy в хвосте экрана) — clear, маркер выше уже не важен', () => {
  const busyScreen = [deadScreen, '  ⏵⏵ auto mode on · esc to interrupt · ← 1 agent'].join('\n');
  assert.equal(authSignal(busyScreen, 'unresolved'), 'clear');
});

test('authSignal: остаточный busy-хинт ВЫШЕ хвоста не маскирует auth-состояние', () => {
  // decide() считает busy по всему pane — именно поэтому auth-ветка смотрит только хвост:
  // строка «esc to interrupt», застрявшая в истории, иначе прятала бы мёртвый логин навсегда.
  const staleBusy = ['✻ Sautéed for 39s · esc to interrupt', ...Array(14).fill('  вывод прошлого хода'), deadScreen].join('\n');
  assert.equal(authSignal(staleBusy, 'unresolved'), 'blocked');
});

// --- authVerdictFromFile(file) — тот же вердикт, но по хвосту РЕАЛЬНОГО транскрипта --------
// Транскрипты воркеров — десятки мегабайт (сессии 265k-431k токенов), читать целиком нельзя.
// Читаем окно с конца и РАСШИРЯЕМ его, пока вердикт не определится: между auth-ошибкой и
// концом файла может лежать сколько угодно user-записей от инжектов event-bridge.
// T6: файлы — в песочнице раннера (CLAUDE_CONTROL_TEST_ROOT), не в tmpdir().

test('authVerdictFromFile: auth-ошибка в конце файла — unresolved', () => {
  const root = process.env.CLAUDE_CONTROL_TEST_ROOT;
  const f = path.join(root, 'transcript-tail.jsonl');
  fs.writeFileSync(f, [okAssistant(), authError()].join('\n') + '\n');
  assert.equal(authVerdictFromFile(f), 'unresolved');
});

test('authVerdictFromFile: файла нет — unknown, не падаем', () => {
  assert.equal(authVerdictFromFile(path.join(process.env.CLAUDE_CONTROL_TEST_ROOT, 'нет-такого.jsonl')), 'unknown');
});

test('authVerdictFromFile: ошибка глубже стартового окна — окно расширяется, а не сдаётся', () => {
  // Реальный сценарий инцидента: после auth-ошибки event-bridge продолжал инжектить события
  // часами, и каждый инжект дописывал user-запись. Фиксированное окно упёрлось бы в них и
  // вернуло 'unknown' — то есть сторож снова ничего бы не увидел.
  const root = process.env.CLAUDE_CONTROL_TEST_ROOT;
  const f = path.join(root, 'transcript-deep.jsonl');
  const filler = Array(400).fill(userTurn('x'.repeat(200))).join('\n');
  fs.writeFileSync(f, [authError(), filler].join('\n') + '\n');
  assert.ok(fs.statSync(f).size > 64 * 1024, 'фикстура обязана быть больше стартового окна');
  assert.equal(authVerdictFromFile(f), 'unresolved');
});

// --- authEpisode(prev, observations, now, cfg) — эпизод отказа авторизации ----------------
// Протухший логин бьёт по ВСЕМ воркерам разом, поэтому фаза эпизода живёт в ОДНОМ месте
// (зарезервированный ключ #auth в watchdog-state.json), а не флагами в per-worker state:
// nextState('reset') конструирует запись воркера заново, а ветки close_executed/incident
// заменяют её целиком — любые auth-флаги там бы потерялись.
// Подтверждение — 2 подряд тика со СТАТИЧНЫМ экраном (таймер ходит раз в 5 минут).

const ep = { remindMin: 60 };
const T0 = 1_700_000_000_000;
const obs = (name, signal, screenHash = 'h1') => ({ name, signal, screenHash });

test('authEpisode: первый тик blocked — наблюдение записано, алерта ещё нет', () => {
  const { episode, alert } = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep);
  assert.equal(alert, null);
  assert.ok(episode.members['dept-archivist'], 'воркер взят под наблюдение');
});

test('authEpisode: второй подряд тик с тем же экраном — подтверждение и алерт', () => {
  const first = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const { alert } = authEpisode(first, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  assert.equal(alert.kind, 'new');
  assert.deepEqual(alert.members, ['dept-archivist']);
});

test('authEpisode: экран сменился между тиками — подтверждения нет, наблюдение с нуля', () => {
  const first = authEpisode(null, [obs('cctv-collect', 'blocked', 'h1')], T0, ep).episode;
  const { episode, alert } = authEpisode(first, [obs('cctv-collect', 'blocked', 'h2')], T0 + 300_000, ep);
  assert.equal(alert, null);
  assert.equal(episode.members['cctv-collect'].confirmed, false);
});

test('authEpisode: воркер ожил (clear) — выбывает из эпизода', () => {
  const first = authEpisode(null, [obs('cctv-collect', 'blocked')], T0, ep).episode;
  const { episode } = authEpisode(first, [obs('cctv-collect', 'clear')], T0 + 300_000, ep);
  assert.equal(episode.members['cctv-collect'], undefined);
});

test('authEpisode: unknown не считается выздоровлением — наблюдение сохраняется', () => {
  // Сбой чтения экрана/транскрипта не должен «вылечивать» воркера и обнулять эпизод.
  const first = authEpisode(null, [obs('cctv-collect', 'blocked')], T0, ep).episode;
  const { episode } = authEpisode(first, [obs('cctv-collect', 'unknown')], T0 + 300_000, ep);
  assert.ok(episode.members['cctv-collect'], 'наблюдение на месте');
});

test('authEpisode: воркер исчез из реестра (нет наблюдения вовсе) — выбывает из эпизода', () => {
  // Иначе снесённый/остановленный воркер висел бы в members вечно и держал эпизод открытым.
  const first = authEpisode(null, [obs('preza-marp', 'blocked')], T0, ep).episode;
  const { episode } = authEpisode(first, [], T0 + 300_000, ep);
  assert.equal(episode.members['preza-marp'], undefined);
});

// --- authNotified(episode, alert, now) — фиксация ФАКТА доставки ---------------------------
// Двухфазность обязательна: пометить «уведомлён» до успешной отправки значит съесть алерт
// на сетевом сбое Telegram (тот же принцип, что p3#33 для alerted в основной лестнице).

test('authNotified: после доставки тот же состав повторно не алертится', () => {
  const first = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const second = authEpisode(first, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  const committed = authNotified(second.episode, second.alert, T0 + 300_000);
  const third = authEpisode(committed, [obs('dept-archivist', 'blocked')], T0 + 600_000, ep);
  assert.equal(third.alert, null);
});

test('authEpisode: доставка провалилась (authNotified не вызван) — следующий тик алертит снова', () => {
  const first = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const second = authEpisode(first, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  assert.equal(second.alert.kind, 'new');
  const third = authEpisode(second.episode, [obs('dept-archivist', 'blocked')], T0 + 600_000, ep);
  assert.equal(third.alert.kind, 'new', 'алерт не потерян — повторяем, пока не доставим');
});

test('authEpisode: добавился второй воркер — в алерте ПОЛНЫЙ список, а не дельта', () => {
  // Оператору нужен весь список пострадавших в одном сообщении, иначе он не поймёт масштаб.
  let e1 = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const r2 = authEpisode(e1, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  e1 = authNotified(r2.episode, r2.alert, T0 + 300_000);
  const r3 = authEpisode(e1, [obs('dept-archivist', 'blocked'), obs('cctv-collect', 'blocked')], T0 + 600_000, ep);
  const r4 = authEpisode(r3.episode, [obs('dept-archivist', 'blocked'), obs('cctv-collect', 'blocked')], T0 + 900_000, ep);
  assert.deepEqual(r4.alert.members, ['cctv-collect', 'dept-archivist']);
});

test('authEpisode: состав не менялся, прошёл remindMin — напоминание', () => {
  // Алерт в 00:40, пока оператор спит, иначе снова превращается в 8 часов простоя.
  const first = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const second = authEpisode(first, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  const committed = authNotified(second.episode, second.alert, T0 + 300_000);
  const later = authEpisode(committed, [obs('dept-archivist', 'blocked')], T0 + 300_000 + 61 * 60_000, ep);
  assert.equal(later.alert.kind, 'remind');
  assert.deepEqual(later.alert.members, ['dept-archivist']);
});

test('authEpisode: все ожили — эпизод закрыт (ни members, ни notified)', () => {
  const first = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const second = authEpisode(first, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  const committed = authNotified(second.episode, second.alert, T0 + 300_000);
  const closed = authEpisode(committed, [obs('dept-archivist', 'clear')], T0 + 600_000, ep);
  assert.deepEqual(closed.episode.members, {});
  assert.deepEqual(closed.episode.notified, []);
  assert.equal(closed.alert, null);
});

test('authEpisode: воркер ожил и упал СНОВА — это новый участник, алерт повторяется', () => {
  // Если не чистить notified при выбытии, повторный отказ того же воркера прошёл бы молча.
  let e = authEpisode(null, [obs('dept-archivist', 'blocked')], T0, ep).episode;
  const r2 = authEpisode(e, [obs('dept-archivist', 'blocked')], T0 + 300_000, ep);
  e = authNotified(r2.episode, r2.alert, T0 + 300_000);
  e = authEpisode(e, [obs('dept-archivist', 'clear')], T0 + 600_000, ep).episode;
  e = authEpisode(e, [obs('dept-archivist', 'blocked')], T0 + 900_000, ep).episode;
  const again = authEpisode(e, [obs('dept-archivist', 'blocked')], T0 + 1_200_000, ep);
  assert.equal(again.alert.kind, 'new');
});

test('authSignal: чистый экран + нечитаемый транскрипт — clear, а не unknown', () => {
  // Иначе воркер, попавший в эпизод, залипает в нём навсегда: 'unknown' наблюдение не
  // снимает, и групповой алерт напоминает про уже живого воркера раз в час.
  const aliveScreen = ['⏺ Готово, задачу закрыл.', '──── prodmash ──', '❯ ', '────'].join('\n');
  assert.equal(authSignal(aliveScreen, 'unknown'), 'clear');
});

test('authSignal: без маркера на экране транскрипт не читается вовсе (ленивый вердикт)', () => {
  // Сторож ходит раз в 5 минут по ~20 воркерам; читать хвост многомегабайтного транскрипта
  // у каждого здорового воркера — лишняя работа на ровном месте.
  let calls = 0;
  const aliveScreen = ['⏺ Готово.', '❯ '].join('\n');
  assert.equal(authSignal(aliveScreen, () => { calls++; return 'unresolved'; }), 'clear');
  assert.equal(calls, 0, 'транскрипт прочитан без нужды');
});

test('authSignal: маркер на экране — вердикт запрашивается и решает исход', () => {
  let calls = 0;
  assert.equal(authSignal(deadScreen, () => { calls++; return 'unresolved'; }), 'blocked');
  assert.equal(calls, 1);
});
