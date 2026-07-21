import './lib/bootstrap.mjs';
import { makeTestSubroot, buildEnv } from './lib/sandbox.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const { pickExecutable, newProbeLines, decideSleep, EXEC_KINDS, stuckExecuting, runnerArgv, humanApproval, staleOpenApprovals, openReminderLabel } = createRequire(import.meta.url)('../bin/dept-dispatcher');

const LEDGER = new URL('../bin/dept-ledger', import.meta.url).pathname;
// T6: журнал сценария живёт в СВОЁМ подкорне (makeTestSubroot), а не в `mkdtempSync(tmpdir())`
// — под маркером резолвер T1 считает корень единственным источником правды и законно
// отвергает DEPT_HOME, указывающий наружу песочницы. Первый аргумент — объект подкорня.
const led = (w, args) => execFileSync(LEDGER, args, { env: buildEnv(w.env), encoding: 'utf8' });

test('EXEC_KINDS: только исполняемые диспетчером kind_of', () => {
  assert.deepEqual([...EXEC_KINDS].sort(), ['liveness_restart', 'mission_change', 'planerka', 'sleep', 'worker_spawn']);
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

// T2 сторож-кнопки (plan п.5): liveness_restart — ОТДЕЛЬНАЯ, УЖЕ ветка от общего правила
// выше — исполняется, только если заявку подал буквально 'watchdog'. Ни руководитель
// (даже с ролью в реестре), ни 'operator', ни любой другой воркер — НЕ проходят, в
// отличие от worker_spawn/mission_change/planerka/sleep, где руководитель/operator ок.
test('pickExecutable: liveness_restart исполняется ТОЛЬКО от watchdog', () => {
  const roleOf = (n) => ({ 'dept-head': 'руководитель' }[n]);
  const rows = [
    { event_id: 'lr1', data: { kind_of: 'liveness_restart', from: 'watchdog' } },   // ок
    { event_id: 'lr2', data: { kind_of: 'liveness_restart', from: 'dept-head' } },  // руководитель — НЕ проходит
    { event_id: 'lr3', data: { kind_of: 'liveness_restart', from: 'operator' } },   // operator — тоже НЕ проходит
    { event_id: 'lr4', data: { kind_of: 'liveness_restart', from: 'mk-a' } },       // подставной воркер — нет
  ];
  assert.deepEqual(pickExecutable(rows, roleOf).map((r) => r.event_id), ['lr1']);
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

// Task 11-fix: заявка, помеченная executing, НЕ должна попадать в повторное исполнение —
// pickExecutable сам не смотрит на статус (принимает уже отфильтрованные rows), реальная
// защита — dept-ledger list --status approved считает effectiveStatus и НЕ вернёт заявку,
// у которой уже есть approval_status(executing). Этот тест проверяет ВСЮ цепочку (ledger
// CLI + pickExecutable), а не только чистую функцию — иначе регрессия в effectiveStatus
// осталась бы незамеченной юнит-тестом на синтетических данных.
test('pickExecutable через реальный ledger: заявка со статусом executing не попадает в approved-выборку', () => {
  const w = makeTestSubroot('dept-');
  const roleOf = (n) => ({ 'dept-head': 'руководитель' }[n]);
  const a = JSON.parse(led(w, ['approval-open', '--kind-of', 'worker_spawn', '--summary', 's', '--actor', 'dept-head']));
  const b = JSON.parse(led(w, ['approval-open', '--kind-of', 'planerka', '--summary', 's2', '--actor', 'dept-head']));
  led(w, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  led(w, ['approval-resolve', b.event_id, '--status', 'approved', '--actor', 'operator']);
  led(w, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']); // "другой тик уже взял"
  const approvedRows = led(w, ['list', '--kind', 'approval', '--status', 'approved'])
    .trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const executable = pickExecutable(approvedRows, roleOf);
  assert.deepEqual(executable.map((r) => r.event_id), [b.event_id]); // только b, a уже executing
});

// stuckExecuting — чистая функция recovery-детекта (Task 11-fix): rows — уже joined-список
// {event_id, kind_of, executing_since} (caller строит через approval(--status executing) +
// approval_status(status=executing) в dept-dispatcher), maxMin — порог в минутах.
test('stuckExecuting: заявка старше порога — зависла; свежая и без executing_since — нет', () => {
  const now = Date.parse('2026-07-15T12:00:00Z');
  const rows = [
    { event_id: 'e1', kind_of: 'planerka', executing_since: new Date(now - 25 * 60_000).toISOString() }, // 25 мин — зависла
    { event_id: 'e2', kind_of: 'sleep', executing_since: new Date(now - 5 * 60_000).toISOString() },     // 5 мин — свежая, ок
    { event_id: 'e3', kind_of: 'worker_spawn', executing_since: new Date(now - 20 * 60_000).toISOString() }, // ровно порог — не зависла (строго >)
  ];
  const stuck = stuckExecuting(rows, now, 20);
  assert.deepEqual(stuck.map((r) => r.event_id), ['e1']);
});

test('stuckExecuting: пустой список / все свежие — пусто', () => {
  const now = Date.now();
  assert.deepEqual(stuckExecuting([], now, 20), []);
  assert.deepEqual(stuckExecuting([{ event_id: 'e1', executing_since: new Date(now - 1000).toISOString() }], now, 20), []);
});

// Фидбэк оператора 16.07: алерты «заявка evt_…» нечитаемы без ledger — humanApproval строит
// человеческую метку из summary/from заявки; при пустых полях — честный fallback на голый id.
test('humanApproval: «<summary> — заявка <from> (<id>)»; fallback на голый id при пустых полях', () => {
  assert.equal(humanApproval({ event_id: 'evt_1_ab', summary: 'найм: МК «диаверум-русс» (diaverum-russ)', from: 'dept-head' }),
    'найм: МК «диаверум-русс» (diaverum-russ) — заявка dept-head (evt_1_ab)');
  assert.equal(humanApproval({ event_id: 'evt_2_cd' }), 'заявка evt_2_cd'); // нет summary — голый id
  assert.equal(humanApproval({ event_id: 'evt_3_ef', summary: '   ', from: 'x' }), 'заявка evt_3_ef'); // пробельный summary = пустой
  assert.equal(humanApproval({ event_id: 'evt_4_gh', summary: 'усыпить воркера x' }), 'усыпить воркера x — заявка ? (evt_4_gh)'); // нет from — «?»
});

test('humanApproval: summary схлопывается в одну строку и режется до 120 codepoints', () => {
  assert.equal(humanApproval({ event_id: 'e', summary: 'стр1\nстр2\tстр3', from: 'f' }), 'стр1 стр2 стр3 — заявка f (e)');
  const label = humanApproval({ event_id: 'e', summary: 'д'.repeat(150), from: 'f' });
  assert.equal(label, 'д'.repeat(120) + '… — заявка f (e)'); // кириллица режется по символам, не по UTF-16 units
});

test('newProbeLines: legacy back-compat — маркированная строка, чей legacy-хэш уже в .seen, подавляется', () => {
  // Codex-аудит В4: доставленное ДО появления stable-id не должно ложно будить контур —
  // тот же дедуп, что делает event-bridge-watch при миграции (записывает g:<id> и не шлёт повторно).
  const visible = '[dept-message] старое до миграции id';
  const legacy = createHash('sha256').update(visible).digest('hex').slice(0, 32);
  const lines = [`\x1eebid=evt_9\x1e${visible}`];
  assert.equal(newProbeLines(lines, new Set([legacy]), new Set()).length, 0);
});

// P3-CRITICAL-2: раннер обязан жить в СОБСТВЕННОМ transient-юните (systemd-run), не
// detached-ребёнком — cgroup-зачистка oneshot-тика убивала его через миллисекунды
// (вскрыто первым боевым наймом 2026-07-16; репродукция в песочнице). Проверяем сборку
// argv: имя юнита от event_id, --collect, прокидка ТОЛЬКО whitelist-env, хвост раннера.
test('runnerArgv: transient-юнит + прокидка whitelist-env + argv раннера', () => {
  const argv = runnerArgv('evt_1_abcd', '/repo/bin/dept-exec-runner', '/repo/bin/dept-spawn-exec',
    { PATH: '/x:/y', CLAUDE_CONTROL_DIR: '/cc', BRAIN_CLIENTS: '/bc', TELEGRAM_NOTIFY: '/tg',
      CLAUDE_AUTO_STALE_SECONDS: '3600',
      CLAUDE_AUTO_HOME: '/dead', HOME: '/home/u', SECRET: 'no' });
  assert.deepEqual(argv.slice(0, 4), ['--user', '--collect', '--quiet', '--unit=dept-runner-evt_1_abcd']);
  const forwarded = argv.filter((_, i) => argv[i - 1] === '--setenv');
  // ревью P3-CRITICAL-2: прокидывается ровно то, что читает bash-цепочка раннера
  // (M-4: + CLAUDE_AUTO_STALE_SECONDS — STALE-гард cmd_rebase в цепочке planerka/
  // mission-exec); CLAUDE_AUTO_HOME (node-only), HOME, SECRET — НЕ прокидываются.
  assert.deepEqual(forwarded, ['PATH=/x:/y', 'CLAUDE_CONTROL_DIR=/cc', 'BRAIN_CLIENTS=/bc', 'TELEGRAM_NOTIFY=/tg', 'CLAUDE_AUTO_STALE_SECONDS=3600']);
  assert.deepEqual(argv.slice(-5), ['/repo/bin/dept-exec-runner', '--approval', 'evt_1_abcd', '--executor', '/repo/bin/dept-spawn-exec']);
});

test('runnerArgv: пустые env-значения не прокидываются', () => {
  const argv = runnerArgv('evt_2_bcde', '/r', '/e', { PATH: '', DEPT_HOME: '/d' });
  const forwarded = argv.filter((_, i) => argv[i - 1] === '--setenv');
  assert.deepEqual(forwarded, ['DEPT_HOME=/d']);
});

// Task 7: напоминание о заявках, зависших open без решения (кейс 16.07 — rfpf 18ч не
// всплыла нигде). rows — сырые события ledger (list --kind approval --status open),
// data.{kind_of,from,summary} лежат ВНУТРИ data (не путать с плоскими row.summary/row.from,
// которые ждёт humanApproval — уплощение делает caller в dept-dispatcher, не эта функция).
test('staleOpenApprovals: заявка старше порога — напомнить; свежая — нет', () => {
  const now = Date.parse('2026-07-17T12:00:00Z');
  const rows = [
    { event_id: 'evt_1_aaaa', ts: '2026-07-16T12:00:00Z', data: { kind_of: 'outgoing', from: 'mk-a', summary: 'старая' } },
    { event_id: 'evt_2_bbbb', ts: '2026-07-17T11:30:00Z', data: { kind_of: 'outgoing', from: 'mk-b', summary: 'свежая' } },
  ];
  const stale = staleOpenApprovals(rows, now, 240);
  assert.equal(stale.length, 1);
  assert.equal(stale[0].event_id, 'evt_1_aaaa');
});

test('staleOpenApprovals: битый ts не роняет и не считается зависшим', () => {
  const now = Date.parse('2026-07-17T12:00:00Z');
  assert.deepEqual(staleOpenApprovals([{ event_id: 'evt_3_cccc', ts: 'мусор', data: { kind_of: 'outgoing', from: 'mk-a', summary: 'x' } }], now, 240), []);
});

// M5 (Codex-аудит): напоминание о зависших open-заявках читало s.data.summary/s.data.from
// БЕЗ страховки — битая/безполевая строка approval роняла бы TypeError'ом весь тик (блок
// стоит ДО исполнения approved-заявок). openReminderLabel — защитное уплощение (см. её
// комментарий в bin/dept-dispatcher, конвенция файла — как targetOfRequest).
test('openReminderLabel: сплющивает data.{summary,from} в плоский row для humanApproval', () => {
  const row = { event_id: 'evt_1_aaaa', ts: '2026-07-16T12:00:00Z', data: { kind_of: 'outgoing', from: 'mk-a', summary: 'старая заявка' } };
  assert.deepEqual(openReminderLabel(row), { event_id: 'evt_1_aaaa', summary: 'старая заявка', from: 'mk-a' });
  assert.equal(humanApproval(openReminderLabel(row)), 'старая заявка — заявка mk-a (evt_1_aaaa)');
});
test('openReminderLabel: строка БЕЗ data не роняет (мусор в ledger) — честный fallback на голый id', () => {
  const row = { event_id: 'evt_2_bbbb', ts: '2026-07-16T12:00:00Z' }; // .data отсутствует вовсе
  assert.deepEqual(openReminderLabel(row), { event_id: 'evt_2_bbbb', summary: undefined, from: undefined });
  assert.equal(humanApproval(openReminderLabel(row)), 'заявка evt_2_bbbb'); // не бросает
});
