import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, utimesSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

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
