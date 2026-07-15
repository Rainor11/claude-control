import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { renderApprovalsPage, renderApproval, renderOffice, renderTimeline, renderActivity, renderIncidents } =
  require('../bin/dept-inbox-render.js');

const apr = { event_id: 'evt_1_aaaa', ts: new Date().toISOString(), actor: 'mk-prodmash',
  data: { kind_of: 'outgoing', from: 'mk-prodmash', status: 'open',
    summary: 'письмо в <script>alert(1)</script>', detail: 'полный текст письма' } };

// ---------------------------------------------------------------------------
// renderApprovalsPage (бывший renderInbox — перенос на /approvals, фаза 3)
// ---------------------------------------------------------------------------

test('renderApprovalsPage показывает открытый аппрув и экранирует HTML', () => {
  const html = renderApprovalsPage({ approvals: [apr], incidents: [], recent: [], executed: [],
    registry: { workers: {} }, policy: { version: 'v2' } });
  assert.ok(html.includes('evt_1_aaaa'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('<script>alert'));
  assert.ok(html.includes('v2'));
});

test('renderApprovalsPage на пустых данных не падает', () => {
  const html = renderApprovalsPage({ approvals: [], incidents: [], recent: [], executed: [],
    registry: { workers: {} }, policy: {} });
  assert.ok(html.includes('пусто'));
});

test('renderApprovalsPage: блок «исполнение» — executed/exec_failed за 7 дней', () => {
  const html = renderApprovalsPage({ approvals: [], incidents: [], recent: [],
    executed: [{ ts: new Date().toISOString(), event_id: 'evt_2', data: { status: 'executed', ref: 'evt_2', note: 'спавн выполнен' } },
      { ts: new Date().toISOString(), event_id: 'evt_3', data: { status: 'exec_failed', ref: 'evt_3', note: 'systemctl упал' } }],
    registry: { workers: {} }, policy: {} });
  assert.ok(html.includes('executed') || html.includes('исполнен'));
  assert.ok(html.includes('exec_failed') || html.includes('ошиб'));
  assert.ok(html.includes('спавн выполнен'));
  assert.ok(html.includes('systemctl упал'));
});

test('renderApproval показывает detail и историю статусов', () => {
  const html = renderApproval(apr, [{ ts: '2026-07-13T10:00:00Z', actor: 'operator',
    data: { status: 'approved', ref: 'evt_1_aaaa' } }]);
  assert.ok(html.includes('полный текст письма'));
  assert.ok(html.includes('approved'));
});

test('renderApproval для неизвестного id — страница «не найдено»', () => {
  assert.ok(renderApproval(null, []).includes('не найден'));
});

test('renderApproval при ошибке чтения — баннер, не «не найден»-маскировка', () => {
  const html = renderApproval(null, [], 'журнал недоступен (см. лог сервиса)');
  assert.ok(html.includes('Ошибка чтения журнала'));
  assert.ok(html.includes('журнал недоступен (см. лог сервиса)'));
  assert.ok(!html.includes('не найден'));
});

test('renderApproval с событием и readError — и карточка, и баннер', () => {
  const html = renderApproval(apr, [], 'история статусов недоступна');
  assert.ok(html.includes('Ошибка чтения журнала'));
  assert.ok(html.includes('полный текст письма'));
});

test('renderApproval без readError (два аргумента) — баннера нет', () => {
  assert.ok(!renderApproval(apr, []).includes('Ошибка чтения журнала'));
  assert.ok(!renderApproval(null, []).includes('Ошибка чтения журнала'));
});

test('кривой/отсутствующий ts рисуется как «?», а не NaN', () => {
  const bad = { ...apr, ts: undefined };
  const html = renderApproval(bad, []);
  assert.ok(!html.includes('NaN'), 'NaN просочился в возраст');
  assert.ok(html.includes('(? назад)'));
});

test('renderApproval раскрашивает unified diff построчно', () => {
  const d = { ...apr, data: { ...apr.data, detail: '--- a\n+++ b\n@@ -1 +1 @@\n-старое\n+новое\n контекст' } };
  const html = renderApproval(d, []);
  assert.ok(html.includes('<pre class="diff">'));
  assert.ok(html.includes('<span class="da">+новое</span>'));
  assert.ok(html.includes('<span class="dd">-старое</span>'));
});

// Codex-аудит К4: если у аппрува есть data.request — рендерить отдельным блоком
// «Заявка (исполняемые данные)», чтобы оператор видел РОВНО то, что исполнит диспетчер.
test('renderApproval: блок «Заявка» из data.request (Codex К4)', () => {
  const withReq = { ...apr, data: { ...apr.data, kind_of: 'worker_spawn',
    request: { client: 'продмаш', name: 'mk-prodmash', gid: '123', note: 'срочно <b>важно</b>' } } };
  const html = renderApproval(withReq, []);
  assert.ok(html.includes('Заявка'));
  assert.ok(html.includes('продмаш'));
  assert.ok(html.includes('mk-prodmash'));
  assert.ok(html.includes('&lt;b&gt;важно&lt;/b&gt;'));
  assert.ok(!html.includes('<b>важно</b>'));
});

test('renderApproval: mission_text из data.request раскрывается через <details>', () => {
  const withReq = { ...apr, data: { ...apr.data, kind_of: 'mission_change',
    request: { worker: 'mk-x', reason: 'смена фокуса', mission_text: 'полный текст новой миссии' } } };
  const html = renderApproval(withReq, []);
  assert.ok(html.includes('<details'));
  assert.ok(html.includes('полный текст новой миссии'));
});

test('renderApproval: без data.request блока «Заявка» нет', () => {
  const html = renderApproval(apr, []);
  assert.ok(!html.includes('Заявка (исполняемые данные)'));
});

// ---------------------------------------------------------------------------
// renderOffice — «Офис» (Task 9)
// ---------------------------------------------------------------------------

test('renderOffice: карточка воркера с ролью, статусом и клиентом', () => {
  const html = renderOffice({
    workers: [{ name: 'mk-prodmash', role: 'мк', client: 'продмаш', state: 'active', unitUp: true,
      missionVersion: 'v3', policyAck: { version: 'v3', ageMin: 30 }, ctx: { tokens: 120000, threshold: 700000 },
      compactions: 1, lastActivityMin: 12, probes: ['dept-bus', 'asana-deal'], openApprovals: 0, openIncidents: 0 }],
    legacyCount: 9, sleepingCount: 0, policy: { version: 'v3' }, openApprovals: 2, openIncidents: 1, readError: null });
  assert.ok(html.includes('mk-prodmash'));
  assert.ok(html.includes('продмаш'));
  assert.ok(html.includes('🤝'));       // аватар роли мк
  assert.ok(html.includes('🟢'));       // в строю
  assert.ok(html.includes('/w/mk-prodmash'));
});

test('renderOffice: статус-приоритет — инцидент бьёт сон и очередь', () => {
  const html = renderOffice({ workers: [{ name: 'w1', role: 'тп', state: 'sleeping', unitUp: false,
    openIncidents: 1, openApprovals: 1, probes: [] }], legacyCount: 0, sleepingCount: 1,
    policy: {}, openApprovals: 1, openIncidents: 1, readError: null });
  assert.ok(html.includes('🔴'));
  assert.ok(!html.includes('😴 w1')); // бейдж один, высший приоритет
});

test('renderOffice: статус «ждёт человека» бьёт сон, но не инцидент', () => {
  const html = renderOffice({ workers: [{ name: 'w2', role: 'руководитель', state: 'active', unitUp: true,
    openIncidents: 0, openApprovals: 1, probes: [] }], legacyCount: 0, sleepingCount: 0,
    policy: {}, openApprovals: 1, openIncidents: 0, readError: null });
  assert.ok(html.includes('⏳'));
  assert.ok(html.includes('👔')); // аватар роли руководитель
});

test('renderOffice: down — state active, но юнит не поднят', () => {
  const html = renderOffice({ workers: [{ name: 'w3', role: 'архивариус', state: 'active', unitUp: false,
    openIncidents: 0, openApprovals: 0, probes: [] }], legacyCount: 0, sleepingCount: 0,
    policy: {}, openApprovals: 0, openIncidents: 0, readError: null });
  assert.ok(html.includes('⛔'));
  assert.ok(html.includes('📚')); // аватар роли архивариус
});

test('renderOffice: экранирует client/name воркера от инъекции', () => {
  const html = renderOffice({ workers: [{ name: 'w<script>1', role: 'мк', client: '<img onerror=1>',
    state: 'active', unitUp: true, openIncidents: 0, openApprovals: 0, probes: [] }],
    legacyCount: 0, sleepingCount: 0, policy: {}, openApprovals: 0, openIncidents: 0, readError: null });
  assert.ok(!html.includes('<script>1'));
  assert.ok(!html.includes('<img onerror=1>'));
});

test('renderOffice: сводная строка — правила/аппрувы/инциденты/спящие', () => {
  const html = renderOffice({ workers: [], legacyCount: 3, sleepingCount: 2,
    policy: { version: 'v5' }, openApprovals: 4, openIncidents: 1, readError: null });
  assert.ok(html.includes('v5'));
  assert.ok(html.includes('/approvals'));
  assert.ok(html.includes('/incidents'));
});

// ---------------------------------------------------------------------------
// renderTimeline — /w/<name>
// ---------------------------------------------------------------------------

test('renderTimeline: события агента и шапка', () => {
  const html = renderTimeline('mk-x', [{ ts: '2026-07-14T10:00:00Z', actor: 'mk-x', kind: 'policy_ack', data: { worker: 'mk-x', policy_version: 'v3' } }], null);
  assert.ok(html.includes('policy_ack'));
});

test('renderTimeline: пустая история не падает', () => {
  const html = renderTimeline('mk-empty', [], null);
  assert.ok(html.includes('mk-empty'));
});

test('renderTimeline: readError показывает баннер', () => {
  const html = renderTimeline('mk-x', [], 'журнал недоступен (см. лог сервиса)');
  assert.ok(html.includes('Ошибка чтения журнала'));
});

// ---------------------------------------------------------------------------
// renderActivity — /activity («бюджеты» v1)
// ---------------------------------------------------------------------------

test('renderActivity: подпись про прокси и sparkline-svg', () => {
  const html = renderActivity([{ name: 'w1', events7d: 5, compactions: 1, wakes: 0, rebases: 1, days: [0,1,0,2,0,0,1,0,0,0,1,0,0,0] }], null);
  assert.ok(html.includes('активность-прокси'));
  assert.ok(html.includes('<svg'));
});

test('renderActivity: sparkline имеет aria-label', () => {
  const html = renderActivity([{ name: 'w1', events7d: 0, compactions: 0, wakes: 0, rebases: 0, days: new Array(14).fill(0) }], null);
  assert.ok(/aria-label="[^"]+"/.test(html));
});

// ---------------------------------------------------------------------------
// renderIncidents — /incidents
// ---------------------------------------------------------------------------

test('renderIncidents: открытые и закрытые инциденты за 14 дней', () => {
  const html = renderIncidents({
    open: [{ ts: new Date().toISOString(), event_id: 'evt_i1', data: { severity: 'high', about_worker: 'prodmash', summary: 'сбой', status: 'open' } }],
    closed: [{ ts: new Date().toISOString(), event_id: 'evt_i2', data: { severity: 'low', about_worker: 'legion2', summary: 'решено', status: 'resolved' } }],
    readError: null,
  });
  assert.ok(html.includes('prodmash'));
  assert.ok(html.includes('legion2'));
  assert.ok(html.includes('high'));
  assert.ok(html.includes('resolved'));
});

// ---------------------------------------------------------------------------
// ИНТЕГРАЦИЯ dl() (p2#10, p2#12, p2#13) — фейковый DEPT_LEDGER_BIN
// ---------------------------------------------------------------------------

const savedEnv = { DEPT_LEDGER_BIN: process.env.DEPT_LEDGER_BIN, DEPT_INBOX_EXEC_TIMEOUT_MS: process.env.DEPT_INBOX_EXEC_TIMEOUT_MS };
function restoreEnv() {
  if (savedEnv.DEPT_LEDGER_BIN === undefined) delete process.env.DEPT_LEDGER_BIN; else process.env.DEPT_LEDGER_BIN = savedEnv.DEPT_LEDGER_BIN;
  if (savedEnv.DEPT_INBOX_EXEC_TIMEOUT_MS === undefined) delete process.env.DEPT_INBOX_EXEC_TIMEOUT_MS; else process.env.DEPT_INBOX_EXEC_TIMEOUT_MS = savedEnv.DEPT_INBOX_EXEC_TIMEOUT_MS;
}

test('dl: timeout зависшего dept-ledger не вешает запрос (p2#12)', async () => {
  const { dl } = require('../bin/dept-inbox');
  process.env.DEPT_LEDGER_BIN = new URL('./fixtures/fake-ledger-hang', import.meta.url).pathname;
  process.env.DEPT_INBOX_EXEC_TIMEOUT_MS = '1000';
  try {
    const t0 = Date.now();
    const r = await dl(['list']);
    assert.ok(Date.now() - t0 < 5000);
    assert.ok(r.error);
  } finally { restoreEnv(); }
});

test('dl: битые строки stdout считаются и всплывают баннером (p2#13)', async () => {
  const { dl } = require('../bin/dept-inbox');
  process.env.DEPT_LEDGER_BIN = new URL('./fixtures/fake-ledger-partial', import.meta.url).pathname;
  delete process.env.DEPT_INBOX_EXEC_TIMEOUT_MS;
  try {
    const r = await dl(['list']);
    assert.equal(r.rows.length, 2);
    assert.match(String(r.error), /пропущен/);
  } finally { restoreEnv(); }
});

test('dl: детали ошибки (stderr/ENOENT) не утекают в error, только generic (p2#11)', async () => {
  const { dl } = require('../bin/dept-inbox');
  process.env.DEPT_LEDGER_BIN = '/nonexistent/dept-ledger-binary-xyz';
  delete process.env.DEPT_INBOX_EXEC_TIMEOUT_MS;
  try {
    const r = await dl(['list']);
    assert.ok(r.error);
    assert.ok(!/ENOENT/.test(r.error));
    assert.equal(r.rows.length, 0);
  } finally { restoreEnv(); }
});

test('ошибка чтения: HTML содержит generic-текст, не stderr-детали (p2#11)', () => {
  const html = renderOffice({ workers: [], legacyCount: 0, sleepingCount: 0, policy: {},
    openApprovals: 0, openIncidents: 0, readError: 'journал недоступен' });
  assert.ok(html.includes('журнал недоступен') || html.includes('данные могут быть неполными'));
  assert.ok(!html.includes('ENOENT'));   // сырые детали не утекают
});
