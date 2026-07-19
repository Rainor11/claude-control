import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync, execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, utimesSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { createRequire } from 'node:module';

const execFileP = promisify(execFile);

const CLI = new URL('../bin/dept-ledger', import.meta.url).pathname;
const run = (home, args, input, extraEnv = {}) =>
  execFileSync(CLI, args, { env: { ...process.env, DEPT_HOME: home, ...extraEnv }, input, encoding: 'utf8' });

test('append пишет конверт и монотонный seq', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['append', '--kind', 'incident', '--actor', 'watchdog',
    '--data', '{"about_worker":"x","severity":"high","summary":"hung"}']));
  const b = JSON.parse(run(home, ['append', '--kind', 'incident', '--actor', 'watchdog',
    '--data', '{"about_worker":"y","severity":"low","summary":"slow"}']));
  assert.match(a.event_id, /^evt_\d+_[a-z0-9]{4}$/);
  assert.equal(b.seq, a.seq + 1);
  const lines = readFileSync(join(home, 'events.jsonl'), 'utf8').trim().split('\n');
  assert.equal(lines.length, 2);
  const env0 = JSON.parse(lines[0]);
  assert.equal(env0.kind, 'incident');
  assert.equal(env0.actor, 'watchdog');
  assert.equal(env0.data.severity, 'high');
});

test('append отклоняет неизвестный kind и битый json', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['append', '--kind', 'nonsense', '--data', '{}']));
  assert.throws(() => run(home, ['append', '--kind', 'incident', '--data', '{broken']));
});

test('list фильтрует по kind и полям data', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'incident', '--data', '{"about_worker":"x","severity":"high","summary":"s1"}']);
  run(home, ['append', '--kind', 'agent_run', '--data', '{"worker":"x","run_kind":"wake"}']);
  const out = run(home, ['list', '--kind', 'incident', '--filter', 'about_worker=x']);
  const rows = out.trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].data.summary, 's1');
});

test('протухший лок не блокирует запись', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const lock = join(home, 'events.jsonl.lock');
  writeFileSync(lock, '999999');
  const past = new Date(Date.now() - 120000); // 2 минуты назад — старше порога протухания (60с)
  utimesSync(lock, past, past);
  const env = JSON.parse(run(home, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"x","severity":"high","summary":"stale-lock"}']));
  assert.equal(env.seq, 1);
});

test('битая строка в журнале пропускается, seq продолжается', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"x","severity":"high","summary":"first"}']);
  appendFileSync(join(home, 'events.jsonl'), '{broken\n');
  const res = spawnSync(CLI, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"y","severity":"low","summary":"second"}'],
    { env: { ...process.env, DEPT_HOME: home }, encoding: 'utf8' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  const env = JSON.parse(res.stdout);
  assert.equal(env.seq, 2);
  assert.match(res.stderr, /битая строка/);
  const rows = run(home, ['list', '--kind', 'incident']).trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 2);
});

test('оборванный хвост без \\n чинится: следующее событие не склеивается с ним', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"x","severity":"high","summary":"first"}']);
  // крэш посреди append: частичная строка БЕЗ перевода строки
  appendFileSync(join(home, 'events.jsonl'), '{"v":1,"event_id":"evt_partial');
  const res = spawnSync(CLI, ['append', '--kind', 'incident',
    '--data', '{"about_worker":"y","severity":"low","summary":"second"}'],
    { env: { ...process.env, DEPT_HOME: home }, encoding: 'utf8' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  // без repairTail новое событие приклеивалось к частичной строке и навсегда
  // выпадало из readAll (хотя caller получил event_id/seq)
  const rows = run(home, ['list', '--kind', 'incident']).trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 2);
  assert.equal(rows[1].data.summary, 'second');
});

test('*_status с несуществующим ref отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['append', '--kind', 'message_status',
    '--data', '{"ref":"evt_0_none","status":"acked"}']));
});

test('--data null отклоняется чисто', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(
    () => run(home, ['append', '--kind', 'incident', '--data', 'null']),
    (err) => {
      assert.ok(!String(err.stderr).includes('TypeError'), `stderr: ${err.stderr}`);
      return true;
    }
  );
});

test('send/ack/resolve — жизненный цикл сообщения', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const m = JSON.parse(run(home, ['send', '--type', 'question', '--to', 'руководитель',
    '--subject', 'вопрос по скидке', '--body', 'можно ли 15%?', '--actor', 'mk-prodmash']));
  let q = run(home, ['list', '--kind', 'message', '--filter', 'to=руководитель', '--status', 'queued']);
  assert.equal(q.trim().split('\n').length, 1);
  run(home, ['ack', m.event_id, '--actor', 'руководитель']);
  q = run(home, ['list', '--kind', 'message', '--status', 'queued']).trim();
  assert.equal(q, '');
  run(home, ['resolve', m.event_id, '--status', 'handled', '--actor', 'руководитель']);
  const h = run(home, ['list', '--kind', 'message', '--status', 'handled']).trim().split('\n');
  assert.equal(h.length, 1);
});

test('registry set/get/list', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'mk-prodmash', '--role', 'мк', '--client', 'продмаш']);
  const w = JSON.parse(run(home, ['registry-get', 'mk-prodmash']));
  assert.equal(w.role, 'мк');
  assert.equal(w.client, 'продмаш');
  assert.equal(w.escalates_to, 'operator'); // дефолт
  const all = JSON.parse(run(home, ['registry-list']));
  assert.ok(all.workers['mk-prodmash']);
});

test('incident-open создаёт инцидент и сообщение ТП из реестра', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'dept-tp', '--role', 'тп']);
  run(home, ['incident-open', '--about', 'mk-prodmash', '--severity', 'high',
    '--summary', 'воркер завис', '--actor', 'watchdog']);
  const inc = run(home, ['list', '--kind', 'incident', '--status', 'open']).trim().split('\n');
  assert.equal(inc.length, 1);
  const msg = run(home, ['list', '--kind', 'message', '--filter', 'to=dept-tp']).trim().split('\n');
  assert.equal(msg.length, 1);
  assert.equal(JSON.parse(msg[0]).data.type, 'incident');
});

test('валидация lifecycle: ack несуществующего ref и кривой approval-статус отклоняются', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['ack', 'evt_000_zzzz']));
  const m = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 's']));
  assert.throws(() => run(home, ['approval-resolve', m.event_id, '--status', 'maybe']));
});

test('registry-set без имени воркера отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['registry-set', '--role', 'тп']));
});

test('битый registry.json не перезаписывается', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const registryPath = join(home, 'registry.json');
  writeFileSync(registryPath, '{oops');
  assert.throws(() => run(home, ['registry-set', 'mk-prodmash', '--role', 'мк']));
  assert.equal(readFileSync(registryPath, 'utf8'), '{oops');
});

test('*_status с ref чужого kind отклоняется: approval-resolve по event_id сообщения', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const m = JSON.parse(run(home, ['send', '--type', 'question', '--to', 'руководитель',
    '--subject', 'вопрос', '--body', 'тело', '--actor', 'mk-x']));
  assert.throws(() => run(home, ['approval-resolve', m.event_id, '--status', 'approved']));
});

test('*_status с ref чужого kind отклоняется: ack по event_id approval', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const ap = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 's']));
  assert.throws(() => run(home, ['ack', ap.event_id]));
});

test('incident-open без ТП в реестре — успешен, но предупреждает в stderr', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const res = spawnSync(CLI, ['incident-open', '--about', 'mk-prodmash', '--severity', 'high',
    '--summary', 'воркер завис', '--actor', 'watchdog'],
    { env: { ...process.env, DEPT_HOME: home }, encoding: 'utf8' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.match(res.stderr, /не маршрутизирован/i);
  const inc = run(home, ['list', '--kind', 'incident', '--status', 'open']).trim().split('\n');
  assert.equal(inc.length, 1);
  const msg = run(home, ['list', '--kind', 'message']).trim();
  assert.equal(msg, ''); // сообщение ТП не создано — маршрутизировать некому
});

test('policy-current/ack/check — полный цикл соблюдения правил', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const pol = mkdtempSync(join(tmpdir(), 'pol-'));
  writeFileSync(join(pol, 'policy-v1.md'), '# v1\n');
  writeFileSync(join(pol, 'policy-v2.md'), '# v2\n');
  const env = { DEPT_POLICY_DIR: pol };
  const cur = JSON.parse(run(home, ['policy-current'], undefined, env));
  assert.equal(cur.version, 'v2');
  // ack устаревшей версии отклоняется
  assert.throws(() => run(home, ['policy-ack', '--version', 'v1', '--actor', 'mk-x'], undefined, env));
  // без ack policy-check падает (die → non-zero exit; текст инструкции уходит в stderr)
  assert.throws(() => run(home, ['policy-check', '--worker', 'mk-x'], undefined, env));
  run(home, ['policy-ack', '--version', 'v2', '--actor', 'mk-x'], undefined, env);
  const ok = JSON.parse(run(home, ['policy-check', '--worker', 'mk-x'], undefined, env));
  assert.equal(ok.ok, true);
  assert.equal(ok.policy_version, 'v2');
  // вышла v3 — старый ack невалиден
  writeFileSync(join(pol, 'policy-v3.md'), '# v3\n');
  assert.throws(() => run(home, ['policy-check', '--worker', 'mk-x'], undefined, env));
});

test('кривой DEPT_POLICY_ACK_TTL_HOURS не выключает TTL', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const pol = mkdtempSync(join(tmpdir(), 'pol-'));
  writeFileSync(join(pol, 'policy-v1.md'), '# v1\n');
  const env = { DEPT_POLICY_DIR: pol, DEPT_POLICY_ACK_TTL_HOURS: 'мусор' };
  // Число из мусора — NaN; если бы guard'а не было, `Date.now() - ts > NaN` всегда false,
  // т.е. TTL молча отключился бы (что тоже выглядело бы как ok:true). Здесь фиксируем
  // минимум из задачи: команда не падает и штатно работает на дефолте при кривом env —
  // настоящий TTL-отказ без манипуляции временем не проверить.
  run(home, ['policy-ack', '--version', 'v1', '--actor', 'mk-x'], undefined, env);
  const ok = JSON.parse(run(home, ['policy-check', '--worker', 'mk-x'], undefined, env));
  assert.equal(ok.ok, true);
  assert.equal(ok.policy_version, 'v1');
});

test('шина: матрица топологии (§5 спеки)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'mk-a', '--role', 'мк', '--client', 'а']);
  run(home, ['registry-set', 'mk-b', '--role', 'мк', '--client', 'б']);
  run(home, ['registry-set', 'dept-head', '--role', 'руководитель']);
  run(home, ['registry-set', 'dept-tp', '--role', 'тп']);
  // МК↔МК запрещено (любой тип)
  assert.throws(() => run(home, ['send', '--type', 'handoff', '--to', 'mk-b',
    '--subject', 's', '--actor', 'mk-a']));
  assert.throws(() => run(home, ['send', '--type', 'question', '--to', 'mk-b',
    '--subject', 's', '--actor', 'mk-a']));
  // Руководителю — только question/proposal (не handoff/incident)
  assert.throws(() => run(home, ['send', '--type', 'handoff', '--to', 'dept-head',
    '--subject', 's', '--actor', 'mk-a']));
  run(home, ['send', '--type', 'question', '--to', 'dept-head', '--subject', 's', '--actor', 'mk-a']);
  run(home, ['send', '--type', 'proposal', '--to', 'dept-head', '--subject', 's', '--actor', 'mk-a']);
  // МК ↔ штаб handoff разрешён; штаб → МК тоже
  run(home, ['send', '--type', 'handoff', '--to', 'dept-tp', '--subject', 's', '--actor', 'mk-a']);
  run(home, ['send', '--type', 'question', '--to', 'mk-a', '--subject', 's', '--actor', 'dept-head']);
  // незарегистрированные акторы (operator, legacy) не блокируются
  run(home, ['send', '--type', 'question', '--to', 'mk-a', '--subject', 's', '--actor', 'operator']);
});

test('approval-resolve идемпотентен: повторный resolve тем же статусом не плодит события', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'other', '--summary', 's']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved']);
  const again = JSON.parse(run(home, ['approval-resolve', a.event_id, '--status', 'approved']));
  assert.equal(again.deduped, true);
  const rows = run(home, ['list', '--kind', 'approval_status']).trim().split('\n');
  assert.equal(rows.length, 1); // второго approval_status нет
  // смена статуса (approved → denied) — это НЕ дубль, пишется
  run(home, ['approval-resolve', a.event_id, '--status', 'denied']);
  assert.equal(run(home, ['list', '--kind', 'approval_status']).trim().split('\n').length, 2);
});

test('approval-resolve: два параллельных resolve одним статусом дают ровно одно событие (атомарность под локом)', async () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'other', '--summary', 's']));
  const resolveOnce = () => execFileP(CLI, ['approval-resolve', a.event_id, '--status', 'approved'],
    { env: { ...process.env, DEPT_HOME: home }, encoding: 'utf8' });
  // старый баг: дедуп-чтение (readAll + effectiveStatus) происходило ДО withLock — гонка
  // двух resolve могла дать ОБОИМ увидеть "ещё не resolved" раньше, чем любой из них
  // дописывал событие, и оба писали approval_status (дубль). Теперь readAll + решение
  // deduped/write — под одним withLock, так что второй вызов застаёт уже записанный статус.
  const [{ stdout: o1 }, { stdout: o2 }] = await Promise.all([resolveOnce(), resolveOnce()]);
  const results = [JSON.parse(o1), JSON.parse(o2)];
  const rows = run(home, ['list', '--kind', 'approval_status']).trim().split('\n');
  assert.equal(rows.length, 1); // ровно одна запись, несмотря на два одновременных resolve
  assert.equal(results.filter((r) => r.deduped === true).length, 1);
  assert.equal(results.filter((r) => r.deduped !== true).length, 1);
});

test('registry-set валидирует роль и клиента для мк', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['registry-set', 'x', '--role', 'посторонний']));
  assert.throws(() => run(home, ['registry-set', 'x', '--role', 'мк'])); // без --client
  run(home, ['registry-set', 'x', '--role', 'legacy']); // legacy остаётся валидной меткой
});

test('list --status без --kind отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  assert.throws(() => run(home, ['list', '--status', 'open']));
});

test('incident-resolve закрывает инцидент; duplicate несёт ссылку на основной', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const r = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 's']));
  assert.throws(() => run(home, ['incident-resolve', r.event_id, '--status', 'позже'])); // не из списка
  run(home, ['incident-resolve', r.event_id, '--status', 'resolved']);
  assert.equal(run(home, ['list', '--kind', 'incident', '--status', 'open']).trim(), '');
  const d = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 'дубль']));
  run(home, ['incident-resolve', d.event_id, '--status', 'duplicate', '--ref-main', r.event_id]);
  const st = run(home, ['list', '--kind', 'incident_status']).trim().split('\n').map(JSON.parse);
  assert.equal(st[st.length - 1].data.ref_main, r.event_id);
});

test('incident-resolve: --status duplicate без --ref-main отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const r = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 's']));
  assert.throws(() => run(home, ['incident-resolve', r.event_id, '--status', 'duplicate']));
});

test('incident-resolve: --ref-main на несуществующий event_id отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const r = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 's']));
  assert.throws(() => run(home, ['incident-resolve', r.event_id, '--status', 'duplicate', '--ref-main', 'evt_0_none']));
});

test('incident-resolve: --ref-main на событие не-incident kind отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const r = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 's']));
  const m = JSON.parse(run(home, ['send', '--type', 'question', '--to', 'руководитель',
    '--subject', 's', '--actor', 'x']));
  assert.throws(() => run(home, ['incident-resolve', r.event_id, '--status', 'duplicate', '--ref-main', m.event_id]));
});

test('incident-resolve: --ref-main без --status duplicate отклоняется', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const r = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 's']));
  const d = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 'd']));
  assert.throws(() => run(home, ['incident-resolve', d.event_id, '--status', 'resolved', '--ref-main', r.event_id]));
});

test('approval-open --detail сохраняет detail и policy_version_seen', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const pol = mkdtempSync(join(tmpdir(), 'pol-'));
  writeFileSync(join(pol, 'policy-v2.md'), '# v2\n');
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 's',
    '--detail', 'полный текст письма'], undefined, { DEPT_POLICY_DIR: pol }));
  const row = JSON.parse(run(home, ['list', '--kind', 'approval']).trim());
  assert.equal(row.event_id, a.event_id);
  assert.equal(row.data.detail, 'полный текст письма');
  assert.equal(row.data.policy_version_seen, 'v2'); // §6 спеки: версия правил в каждом approval
  // без каталога правил approval всё равно открывается (аудит-поле опциональное)
  const b = JSON.parse(run(home, ['approval-open', '--kind-of', 'other', '--summary', 's2'],
    undefined, { DEPT_POLICY_DIR: join(pol, 'нет-такого') }));
  assert.ok(b.event_id);
});

test('approval-open --request-json сохраняет data.request; мусор/не-объект/слишком большой — отклоняются', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'worker_spawn', '--summary', 's',
    '--request-json', '{"name":"x"}']));
  const row = JSON.parse(run(home, ['list', '--kind', 'approval', '--event-id', a.event_id]).trim());
  assert.equal(row.data.request.name, 'x');
  // невалидный JSON
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'other', '--summary', 's', '--request-json', '{broken']));
  // не объект (массив/скаляр)
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'other', '--summary', 's', '--request-json', '[1,2]']));
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'other', '--summary', 's', '--request-json', '"x"']));
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'other', '--summary', 's', '--request-json', 'null']));
  // слишком большой (>8000 байт сериализованного JSON) для generic kind_of
  const big = JSON.stringify({ text: 'A'.repeat(8100) });
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'other', '--summary', 's', '--request-json', big]));
});

test('approval-open --request-json: mission_change имеет расширенный кап (22000) для полного текста миссии', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  // ~17000 символов mission_text — за пределами generic-капа 8000, но в пределах mission-капа 22000
  const missionText = 'миссия '.repeat(2500); // ~17500 символов
  const req = JSON.stringify({ worker: 'mk-x', reason: 'смена курса', mission_text: missionText });
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'mission_change', '--summary', 's',
    '--request-json', req, '--detail', 'резюме: смена курса\n\n' + missionText]));
  const row = JSON.parse(run(home, ['list', '--kind', 'approval', '--event-id', a.event_id]).trim());
  assert.equal(row.data.request.mission_text, missionText); // не обрезан
  assert.equal(row.data.detail, 'резюме: смена курса\n\n' + missionText); // detail тоже не обрезан (синхронный кап)

  // >22000 (даже для mission_change) — по-прежнему отклоняется
  const tooBig = JSON.stringify({ worker: 'mk-x', reason: 'x', mission_text: 'A'.repeat(22500) });
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'mission_change', '--summary', 's', '--request-json', tooBig]));

  // generic kind_of НЕ получает расширенный кап — тот же request (17500 симв.) для НЕ-mission_change падает
  assert.throws(() => run(home, ['approval-open', '--kind-of', 'other', '--summary', 's', '--request-json', req]));
});

test('snapshot коммитит журнал и молчит без изменений', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'agent_run', '--data', '{"worker":"x","run_kind":"wake"}']);
  const s1 = JSON.parse(run(home, ['snapshot']));
  assert.equal(s1.committed, true);
  const s2 = JSON.parse(run(home, ['snapshot']));
  assert.equal(s2.committed, false);
  const log = execFileSync('git', ['-C', home, 'log', '--oneline'], { encoding: 'utf8' });
  assert.equal(log.trim().split('\n').length, 1);
  // snapshot идёт под ledger-локом → лок-файл существует в момент git add и обязан
  // игнорироваться (иначе каждый прогон коммитит его и никогда не бывает «чистым»)
  const tracked = execFileSync('git', ['-C', home, 'ls-files'], { encoding: 'utf8' });
  assert.ok(!tracked.includes('events.jsonl.lock'), `лок закоммичен: ${tracked}`);
  assert.ok(tracked.includes('.gitignore'));
});

test('шина: новые типы kb_change_request/decision_request + их топология', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'dept-archivist', '--role', 'архивариус']);
  run(home, ['registry-set', 'dept-head', '--role', 'руководитель']);
  run(home, ['registry-set', 'mk-a', '--role', 'мк', '--client', 'а']);
  // kb_change_request к архивариусу проходит
  run(home, ['send', '--type', 'kb_change_request', '--to', 'dept-archivist',
    '--subject', 'новый факт БЗ', '--actor', 'mk-a']);
  // kb_change_request к НЕ-архивариусу падает
  assert.throws(() => run(home, ['send', '--type', 'kb_change_request', '--to', 'dept-head',
    '--subject', 'x', '--actor', 'mk-a']));
  // decision_request к руководителю проходит, к архивариусу — нет
  run(home, ['send', '--type', 'decision_request', '--to', 'dept-head',
    '--subject', 'нужно решение', '--actor', 'mk-a']);
  assert.throws(() => run(home, ['send', '--type', 'decision_request', '--to', 'dept-archivist',
    '--subject', 'x', '--actor', 'mk-a']));
  // руководителю по-прежнему нельзя handoff
  assert.throws(() => run(home, ['send', '--type', 'handoff', '--to', 'dept-head',
    '--subject', 'x', '--actor', 'mk-a']));
});

test('approval-exec: только после approved, идемпотентно; resolve после exec падает', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'worker_spawn',
    '--summary', 'нанять мк-тест', '--actor', 'dept-head']));
  // exec до approved — отказ
  assert.throws(() => run(home, ['approval-exec', a.event_id, '--status', 'executed', '--actor', 'dispatcher']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  const e1 = JSON.parse(run(home, ['approval-exec', a.event_id, '--status', 'executed', '--actor', 'dispatcher']));
  assert.ok(e1.event_id);
  // идемпотентность
  const e2 = JSON.parse(run(home, ['approval-exec', a.event_id, '--status', 'executed', '--actor', 'dispatcher']));
  assert.equal(e2.deduped, true);
  // resolve на исполненный аппрув — отказ
  assert.throws(() => run(home, ['approval-resolve', a.event_id, '--status', 'denied', '--actor', 'operator']));
});

// Task 11-fix: промежуточный статус executing (дедуп исполнения долгих заявок диспетчером).
// Прямой approved→executed (тест выше) — операторский ручной путь, ОБЯЗАН остаться рабочим.

test('approval-exec: approved→executing→executed проходит, executing идемпотентен', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'worker_spawn',
    '--summary', 'нанять мк-тест', '--actor', 'dept-head']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  const e1 = JSON.parse(run(home, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']));
  assert.ok(e1.event_id);
  assert.notEqual(e1.deduped, true);
  // второй тик/прогон видит уже executing — дедуп, НЕ второе событие
  const e2 = JSON.parse(run(home, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']));
  assert.equal(e2.deduped, true);
  // раннер дописывает финал
  const e3 = JSON.parse(run(home, ['approval-exec', a.event_id, '--status', 'executed', '--actor', 'dispatcher']));
  assert.ok(e3.event_id);
  assert.notEqual(e3.deduped, true);
  const rows = run(home, ['list', '--kind', 'approval_status']).trim().split('\n');
  assert.equal(rows.length, 3); // approved + executing + executed, второй executing НЕ дописан (дедуп)
  assert.equal(run(home, ['list', '--kind', 'approval', '--status', 'executed']).trim().split('\n').length, 1);
});

test('executing виден в list и НЕ попадает в выборку approved', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'planerka', '--summary', 'план', '--actor', 'dept-head']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  run(home, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']);
  const executing = run(home, ['list', '--kind', 'approval', '--status', 'executing']).trim().split('\n').map(JSON.parse);
  assert.equal(executing.length, 1);
  assert.equal(executing[0].event_id, a.event_id);
  const approved = run(home, ['list', '--kind', 'approval', '--status', 'approved']).trim();
  assert.equal(approved, ''); // effectiveStatus теперь executing, НЕ approved — pickExecutable его не увидит
});

test('approval-exec executing блокирует approval-resolve (заявка уже исполняется)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'sleep', '--summary', 'сон', '--actor', 'dept-head']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  run(home, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']);
  assert.throws(
    () => run(home, ['approval-resolve', a.event_id, '--status', 'denied', '--actor', 'operator']),
    (err) => { assert.match(String(err.stderr), /исполня/i); return true; },
  );
});

test('approval-exec: executed→executing отклоняется (финал)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'mission_change', '--summary', 'смена курса', '--actor', 'dept-head']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  run(home, ['approval-exec', a.event_id, '--status', 'executed', '--actor', 'dispatcher']); // прямой путь (back-compat)
  assert.throws(() => run(home, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']));
});

test('rotate: заявка в executing НЕ ротируется (даже старая, даже для generic kind_of)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'worker_spawn', '--summary', 'найм', '--actor', 'dept-head']));
  run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']);
  run(home, ['approval-exec', a.event_id, '--status', 'executing', '--actor', 'dispatcher']);
  const led = join(home, 'events.jsonl');
  const old = new Date(Date.now() - 40 * 86400_000).toISOString();
  writeFileSync(led, readFileSync(led, 'utf8').split('\n').filter(Boolean)
    .map((l) => JSON.stringify({ ...JSON.parse(l), ts: old })).join('\n') + '\n');
  run(home, ['rotate', '--days', '30']);
  const left = run(home, ['list', '--kind', 'approval', '--event-id', a.event_id]).trim();
  assert.ok(left); // жива в активном файле, ротация её не тронула
});

test('list --event-id находит конверт', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'x', '--actor', 'w']));
  const rows = run(home, ['list', '--kind', 'approval', '--event-id', a.event_id]).trim().split('\n');
  assert.equal(rows.length, 1);
  assert.equal(JSON.parse(rows[0]).event_id, a.event_id);
});

test('rotate: закрытые цепочки уходят в архив, открытые и свежие остаются, seq монотонен', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  // закрытое сообщение (старим ts руками — journал правим до вызова rotate, это тест)
  const m = JSON.parse(run(home, ['send', '--type', 'question', '--to', 'w2', '--subject', 'старое', '--actor', 'w1']));
  run(home, ['ack', m.event_id, '--actor', 'w2']);
  run(home, ['resolve', m.event_id, '--status', 'handled', '--actor', 'w2']);
  // открытый approval — не ротируется даже старый
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'жду', '--actor', 'w1']));
  // состарить ВСЕ строки на 40 дней (перезаписью ts в файле)
  const led = join(home, 'events.jsonl');
  const old = new Date(Date.now() - 40 * 86400_000).toISOString();
  writeFileSync(led, readFileSync(led, 'utf8').split('\n').filter(Boolean)
    .map((l) => JSON.stringify({ ...JSON.parse(l), ts: old })).join('\n') + '\n');
  const r = JSON.parse(run(home, ['rotate', '--days', '30']));
  assert.ok(r.rotated >= 3); // message + 2 статуса
  const left = run(home, ['list']).trim().split('\n').filter(Boolean).map((l) => JSON.parse(l));
  assert.ok(left.some((e) => e.event_id === a.event_id)); // открытый жив
  assert.ok(!left.some((e) => e.event_id === m.event_id)); // закрытый уехал
  // архивный файл существует и содержит закрытую цепочку
  const arch = readdirSync(join(home, 'archive'));
  assert.equal(arch.length, 1);
  // seq после ротации продолжается, не начинается с 1
  const n = JSON.parse(run(home, ['send', '--type', 'question', '--to', 'w2', '--subject', 'новое', '--actor', 'w1']));
  const rows = run(home, ['list', '--kind', 'message', '--event-id', n.event_id]).trim();
  assert.ok(JSON.parse(rows).seq > 1);
});

test('rotate: policy_ack — последний ack воркера остаётся, старые уходят', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const pol = mkdtempSync(join(tmpdir(), 'pol-'));
  writeFileSync(join(pol, 'policy-v1.md'), '# v1\n');
  const env = { DEPT_POLICY_DIR: pol };
  run(home, ['policy-ack', '--version', 'v1', '--actor', 'w1'], undefined, env);
  run(home, ['policy-ack', '--version', 'v1', '--actor', 'w1'], undefined, env);
  const led = join(home, 'events.jsonl');
  const old = new Date(Date.now() - 40 * 86400_000).toISOString();
  writeFileSync(led, readFileSync(led, 'utf8').split('\n').filter(Boolean)
    .map((l) => JSON.stringify({ ...JSON.parse(l), ts: old })).join('\n') + '\n');
  JSON.parse(run(home, ['rotate', '--days', '30']));
  const acks = run(home, ['list', '--kind', 'policy_ack']).trim().split('\n').filter(Boolean);
  assert.equal(acks.length, 1); // последний остался, старый уехал
});

test('assertRefExists видит архив: duplicate --ref-main на заархивированный инцидент', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const i1 = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 'основной', '--actor', 'operator']));
  run(home, ['incident-resolve', i1.event_id, '--status', 'resolved', '--actor', 'operator']);
  const led = join(home, 'events.jsonl');
  const old = new Date(Date.now() - 40 * 86400_000).toISOString();
  writeFileSync(led, readFileSync(led, 'utf8').split('\n').filter(Boolean)
    .map((l) => JSON.stringify({ ...JSON.parse(l), ts: old })).join('\n') + '\n');
  JSON.parse(run(home, ['rotate', '--days', '30']));
  // новый инцидент-дубль ссылается на архивный основной — должен пройти
  const i2 = JSON.parse(run(home, ['incident-open', '--about', 'w1', '--severity', 'low', '--summary', 'дубль', '--actor', 'operator']));
  run(home, ['incident-resolve', i2.event_id, '--status', 'duplicate', '--ref-main', i1.event_id, '--actor', 'operator']);
});

test('policy-check: mtime правил новее ack и протухший TTL — оба падают (p2#1)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const pol = mkdtempSync(join(tmpdir(), 'pol-'));
  writeFileSync(join(pol, 'policy-v1.md'), '# v1\n');
  const env = { DEPT_POLICY_DIR: pol };
  run(home, ['policy-ack', '--version', 'v1', '--actor', 'w1'], undefined, env);
  // mtime новее ack: трогаем файл в будущее
  const f = join(pol, 'policy-v1.md');
  const future = new Date(Date.now() + 5_000);
  utimesSync(f, future, future);
  assert.throws(() => run(home, ['policy-check', '--worker', 'w1'], undefined, env));
  // TTL: свежий ack, но TTL крошечный → протух
  utimesSync(f, new Date(Date.now() - 60_000), new Date(Date.now() - 60_000));
  run(home, ['policy-ack', '--version', 'v1', '--actor', 'w1'], undefined, env);
  assert.throws(() => {
    // ждём 1.2с, TTL 0.0002ч = 0.72с
    execFileSync('sleep', ['1.2']);
    run(home, ['policy-check', '--worker', 'w1'], undefined, { ...env, DEPT_POLICY_ACK_TTL_HOURS: '0.0002' });
  });
});

// M-1 (ревью фазы 3): список exec-kinds живёт в 4 копиях (EXEC_KINDS в dept-dispatcher —
// его пинит dept-dispatcher.test.mjs; EXECUTORS там же; WHITELIST в dept-exec-runner;
// EXEC_KINDS_ROT здесь, в rotate). Разъезд копий = тихая потеря заявки: rotate унесёт
// approved-заявку нового kind_of в архив, а dispatcher читает только активный файл.
// Пин текстом (модуль bash-стиля не экспортируешь): регекс по строке объявления.
test('EXEC_KINDS_ROT (rotate) синхронен с EXEC_KINDS dispatcher и WHITELIST dept-exec-runner', () => {
  const src = readFileSync(CLI, 'utf8');
  const m = /EXEC_KINDS_ROT\s*=\s*new Set\(\[([^\]]*)\]\)/.exec(src);
  assert.ok(m, 'EXEC_KINDS_ROT не найден в bin/dept-ledger — переименовали? обнови тест и сверь 4 копии');
  const kinds = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]).sort();
  assert.deepEqual(kinds, ['mission_change', 'planerka', 'sleep', 'worker_spawn']);
});

test('die-под-локом: approval-resolve на несуществующий ref не держит лок (Codex-аудит В3)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  // validateEvent/assertRefExists теперь кидают cliError вместо die() изнутри withLock —
  // если бы лок остался висеть, следующая команда ждала бы withLock'овский 10с-таймаут.
  assert.throws(() => run(home, ['approval-resolve', 'evt_0_none', '--status', 'approved']));
  assert.doesNotThrow(() => run(home, ['append', '--kind', 'agent_run', '--data', '{"worker":"x","run_kind":"wake"}']));
});

// Дыра 17.07: гард К3 (assertNotWorkerSession) стоял только на approval-resolve/approval-exec,
// а generic append/registry-set писали ТЕ ЖЕ привилегированные события в обход. Тесты ниже
// покрывают то, что тестируемо без подделки /proc (обратного шва для эмуляции воркера нет) —
// см. брифинг Task 0.

test('PRIVILEGED_KINDS: пин списка привилегированных типов события', () => {
  const src = readFileSync(CLI, 'utf8');
  const m = /PRIVILEGED_KINDS\s*=\s*new Set\(\[([^\]]*)\]\)/.exec(src);
  assert.ok(m, 'PRIVILEGED_KINDS не найден — переименовали? обнови тест');
  const kinds = [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]).sort();
  // approval_status — самоодобрение; registry_change — самоповышение до руководителя;
  // incident_status — закрытие инцидента о себе; policy_ack — ack за другого воркера.
  assert.deepEqual(kinds, ['approval_status', 'incident_status', 'policy_ack', 'registry_change']);
});

test('append привилегированного типа зовёт гард сессии воркера', () => {
  const src = readFileSync(CLI, 'utf8');
  const fn = src.slice(src.indexOf('function cmdAppend'), src.indexOf('function cmdList'));
  assert.match(fn, /assertNotWorkerSession/,
    'cmdAppend обязан звать assertNotWorkerSession для привилегированных kind — иначе approval-resolve обходится generic append (дыра 17.07)');
});

test('registry-set зовёт гард сессии воркера (самоповышение до руководителя)', () => {
  const src = readFileSync(CLI, 'utf8');
  const fn = src.slice(src.indexOf('function cmdRegistrySet'), src.indexOf('function cmdRegistryGet'));
  assert.match(fn, /assertNotWorkerSession/,
    'cmdRegistrySet обязан звать гард — иначе воркер назначает себя руководителем и его заявки берёт pickExecutable');
});

test('append НЕпривилегированного типа по-прежнему свободен (agent_run пишет claude-auto)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const r = JSON.parse(run(home, ['append', '--kind', 'agent_run', '--data',
    JSON.stringify({ worker: 'w', run_kind: 'rebase' })]));
  assert.ok(r.event_id, 'agent_run обязан оставаться доступным — его пишет claude-auto из сессии воркера при rebase');
});

test('append approval_status от НЕ-воркера проходит (бот/оператор/диспетчер)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'other', '--summary', 'x', '--actor', 'mk-a']));
  const r = JSON.parse(run(home, ['append', '--kind', 'approval_status', '--data',
    JSON.stringify({ ref: a.event_id, status: 'approved' }), '--actor', 'operator']));
  assert.ok(r.event_id, 'тесты идут не из сессии воркера — гард обязан пропустить');
});

test('send --type policy_refresh: валидный тип шины', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'mk-a', '--role', 'мк', '--client', 'кли']);
  const r = JSON.parse(run(home, ['send', '--type', 'policy_refresh', '--to', 'mk-a',
    '--subject', 'Планёрка: перечитай policy-v9', '--body', 'Причина: тест', '--actor', 'dept-head']));
  const row = JSON.parse(run(home, ['list', '--kind', 'message', '--event-id', r.event_id]));
  assert.equal(row.data.type, 'policy_refresh');
  assert.equal(row.data.from, 'dept-head');
});

test('policy_refresh доходит до РУКОВОДИТЕЛЯ (он тоже перечитывает правила)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'dept-head', '--role', 'руководитель']);
  const r = JSON.parse(run(home, ['send', '--type', 'policy_refresh', '--to', 'dept-head',
    '--subject', 'Планёрка: перечитай policy-v9', '--body', 'Причина: тест', '--actor', 'dept-head']));
  assert.ok(r.event_id, 'policy_refresh руководителю обязан проходить гард §5');
});

test('гард §5 для руководителя не ослаблен: handoff ему по-прежнему запрещён', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'dept-head', '--role', 'руководитель']);
  assert.throws(() => run(home, ['send', '--type', 'handoff', '--to', 'dept-head',
    '--subject', 'x', '--actor', 'mk-a']), /руководителю идут только/);
});

test('policy_refresh МК→МК по-прежнему запрещён (гард 3.1 не ослаблен)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'mk-a', '--role', 'мк', '--client', 'a']);
  run(home, ['registry-set', 'mk-b', '--role', 'мк', '--client', 'b']);
  assert.throws(() => run(home, ['send', '--type', 'policy_refresh', '--to', 'mk-b',
    '--subject', 'x', '--actor', 'mk-a']), /МК→МК запрещено/);
});

test('неизвестный тип сообщения по-прежнему отвергается', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['registry-set', 'mk-a', '--role', 'мк', '--client', 'a']);
  assert.throws(() => run(home, ['send', '--type', 'нет-такого', '--to', 'mk-a',
    '--subject', 'x']), /message.type ∉/);
});

// --- authorizeWithdraw: чистая логика допуска (шва в CLI намеренно нет — см. R16) ---
const { authorizeWithdraw } = createRequire(import.meta.url)('../bin/dept-ledger');
const apr = (from) => ({ event_id: 'evt_1_aaaa', kind: 'approval', data: { from, kind_of: 'outgoing', summary: 'x' } });

test('authorizeWithdraw: автор + open → можно', () => {
  assert.deepEqual(authorizeWithdraw('mk-a', apr('mk-a'), 'open'), { ok: true });
});

test('authorizeWithdraw: НЕ автор → нельзя, даже если заявка open', () => {
  const r = authorizeWithdraw('mk-b', apr('mk-a'), 'open');
  assert.ok(r.err);
  assert.match(r.err, /только автор/i);
});

test('authorizeWithdraw: не из сессии воркера (caller=null) → нельзя', () => {
  const r = authorizeWithdraw(null, apr('mk-a'), 'open');
  assert.ok(r.err);
  assert.match(r.err, /только из сессии воркера/i);
});

test('authorizeWithdraw: заявки нет → нельзя', () => {
  const r = authorizeWithdraw('mk-a', null, null);
  assert.ok(r.err);
  assert.match(r.err, /не найден/i);
});

for (const st of ['approved', 'denied', 'executing', 'executed', 'exec_failed']) {
  test(`authorizeWithdraw: статус ${st} → поздно`, () => {
    const r = authorizeWithdraw('mk-a', apr('mk-a'), st);
    assert.ok(r.err, `${st} обязан блокировать отзыв`);
    assert.match(r.err, /поздно|уже решена/i);
  });
}

test('authorizeWithdraw: повторный отзыв → дедуп, не ошибка', () => {
  assert.deepEqual(authorizeWithdraw('mk-a', apr('mk-a'), 'withdrawn'), { ok: true, deduped: true });
});

// --- CLI: негативный кейс, воспроизводимый без шва ---

test('approval-withdraw: НЕ из сессии воркера запрещён (тесты идут не из воркера)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'x', '--actor', 'mk-a']));
  assert.throws(() => run(home, ['approval-withdraw', a.event_id]), /только из сессии воркера/i);
});

test('approval-withdraw: флага --actor нет (иначе гард обходится подменой имени)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'x', '--actor', 'mk-a']));
  // Как бы ни звали — из НЕ-воркера отзыв невозможен; --actor не даёт представиться автором.
  assert.throws(() => run(home, ['approval-withdraw', a.event_id, '--actor', 'mk-a']), /только из сессии воркера/i);
});

// --- withdrawn как статус: rotate и второй ремень (проверяются через generic append,
//     который после Task 0 доступен НЕ-воркеру — то есть тестам) ---

test('approval-resolve поверх withdrawn отвергается (второй ремень против гонки с кнопкой)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'x', '--actor', 'mk-a']));
  run(home, ['append', '--kind', 'approval_status', '--data',
    JSON.stringify({ ref: a.event_id, status: 'withdrawn' }), '--actor', 'mk-a']);
  assert.throws(() => run(home, ['approval-resolve', a.event_id, '--status', 'approved', '--actor', 'operator']),
    /отозван/i);
});

test('withdrawn убирает заявку из open', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'x', '--actor', 'mk-a']));
  run(home, ['append', '--kind', 'approval_status', '--data',
    JSON.stringify({ ref: a.event_id, status: 'withdrawn' }), '--actor', 'mk-a']);
  assert.equal(run(home, ['list', '--kind', 'approval', '--status', 'open']).trim(), '');
  assert.match(run(home, ['list', '--kind', 'approval', '--status', 'withdrawn']), new RegExp(a.event_id));
});

test('rotate: отозванная заявка считается закрытой и уезжает в архив', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  const a = JSON.parse(run(home, ['approval-open', '--kind-of', 'outgoing', '--summary', 'x', '--actor', 'mk-a']));
  run(home, ['append', '--kind', 'approval_status', '--data',
    JSON.stringify({ ref: a.event_id, status: 'withdrawn' }), '--actor', 'mk-a']);
  const led = join(home, 'events.jsonl');
  const old = new Date(Date.now() - 40 * 86400_000).toISOString();
  writeFileSync(led, readFileSync(led, 'utf8').split('\n').filter(Boolean)
    .map((l) => JSON.stringify({ ...JSON.parse(l), ts: old })).join('\n') + '\n');
  const r = JSON.parse(run(home, ['rotate', '--days', '30']));
  assert.ok(r.rotated >= 2, 'цепочка approval+withdrawn обязана ротироваться, иначе живёт в активном файле вечно');
});

test('rotate чистит старые exec-stuck маркеры и runner-логи (p3#35)', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'agent_run', '--data', JSON.stringify({ worker: 'w', run_kind: 'x' })]);
  const old = (Date.now() - 40 * 86400_000) / 1000;
  const fresh = Date.now() / 1000;
  for (const [f, t] of [['exec-stuck-evt_1_aaaa', old], ['runner-evt_1_aaaa.log', old],
                        ['exec-stuck-evt_2_bbbb', fresh], ['runner-evt_2_bbbb.log', fresh]]) {
    writeFileSync(join(home, f), 'x');
    utimesSync(join(home, f), t, t);
  }
  run(home, ['rotate', '--days', '30']);
  const left = readdirSync(home);
  assert.ok(!left.includes('exec-stuck-evt_1_aaaa'), 'старый маркер обязан быть убран');
  assert.ok(!left.includes('runner-evt_1_aaaa.log'), 'старый лог раннера обязан быть убран');
  assert.ok(left.includes('exec-stuck-evt_2_bbbb'), 'свежий маркер трогать нельзя — заявка может быть in-flight');
  assert.ok(left.includes('runner-evt_2_bbbb.log'), 'свежий лог раннера трогать нельзя');
});

test('rotate не трогает посторонние файлы DEPT_HOME', () => {
  const home = mkdtempSync(join(tmpdir(), 'dept-'));
  run(home, ['append', '--kind', 'agent_run', '--data', JSON.stringify({ worker: 'w', run_kind: 'x' })]);
  const old = (Date.now() - 40 * 86400_000) / 1000;
  for (const f of ['registry.json', 'rebase-check-state.json', 'sleep-check-state.json']) {
    writeFileSync(join(home, f), '{}');
    utimesSync(join(home, f), old, old);
  }
  run(home, ['rotate', '--days', '30']);
  const left = readdirSync(home);
  for (const f of ['registry.json', 'rebase-check-state.json', 'sleep-check-state.json']) {
    assert.ok(left.includes(f), `${f} снесён ротацией — это рантайм-стейт, не мусор`);
  }
});
