// T6: обязательный пролог изоляции (tests/lib/bootstrap.mjs) — первым значимым действием файла.
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const CLI = new URL('../bin/dept-memory-freshness', import.meta.url).pathname;
const { memoryFreshness, memoryFreshnessFromTx, MEMORY_GLOBS } = createRequire(import.meta.url)('../bin/dept-memory-freshness');

const HOUR = 3600_000;
const STALE_AFTER = 1800_000; // 30 мин — дефолт CLAUDE_AUTO_STALE_SECONDS

// Песочница: клиентская папка + фейковый транскрипт по схеме ~/.claude/projects/<dir>/<sid>.jsonl
function sandbox({ files = {}, txAgeMs = 0 }) {
  // T6: песочница сценария — внутри тестового корня раннера (раньше `tmpdir()`), чтобы
  // раннер убрал её за собой. Корнем рантайма этот каталог не является (это brain-путь
  // клиента + фейковый ~/.claude/projects), резолвер T1 его не проверяет.
  const root = mkdtempSync(join(process.env.CLAUDE_CONTROL_TEST_ROOT, 'memfresh-'));
  const brain = join(root, 'клиент');
  mkdirSync(brain, { recursive: true });
  const now = Date.now();
  for (const [name, ageMs] of Object.entries(files)) {
    const f = join(brain, name);
    writeFileSync(f, '# ' + name);
    const t = (now - ageMs) / 1000;
    utimesSync(f, t, t);
  }
  const sid = 'sess-' + Math.random().toString(36).slice(2, 8);
  const proj = join(root, 'projects', '-home-rainor-brain');
  mkdirSync(proj, { recursive: true });
  const tx = join(proj, sid + '.jsonl');
  writeFileSync(tx, '{}');
  const tt = (now - txAgeMs) / 1000;
  utimesSync(tx, tt, tt);
  return { root, brain, sid, projectsRoot: join(root, 'projects') };
}

test('манифест CLAUDE.md считается памятью (кейс vam-mebel: докурировал в манифест — не STALE)', () => {
  // timeline старый, манифест свежий, транскрипт активен 10 мин назад
  const s = sandbox({ files: { 'timeline.md': 40 * HOUR, 'CLAUDE.md': 5 * 60_000 }, txAgeMs: 0 });
  const r = memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot });
  assert.equal(r.state, 'fresh');
  assert.equal(r.newestFile, 'CLAUDE.md');
});

test('трек-файлы многотрековой схемы считаются памятью (кейс elektronika: timeline-контент-агент.md)', () => {
  const s = sandbox({ files: { 'timeline.md': 40 * HOUR, 'timeline-контент-агент.md': 60_000 }, txAgeMs: 0 });
  const r = memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot });
  assert.equal(r.state, 'fresh');
  assert.equal(r.newestFile, 'timeline-контент-агент.md');
});

test('decisions-<трек>.md тоже считается памятью', () => {
  const s = sandbox({ files: { 'decisions-контент-агент.md': 60_000 }, txAgeMs: 0 });
  assert.equal(memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot }).state, 'fresh');
});

test('память реально отстала от транскрипта → stale', () => {
  const s = sandbox({ files: { 'CLAUDE.md': 40 * HOUR, 'timeline.md': 40 * HOUR }, txAgeMs: 0 });
  const r = memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot });
  assert.equal(r.state, 'stale');
  assert.ok(r.gapSec > 30 * 60, 'gapSec должен отражать разрыв транскрипт↔память');
});

test('разрыв меньше порога → fresh (служебный тик не делает память несвежей)', () => {
  const s = sandbox({ files: { 'timeline.md': 20 * 60_000 }, txAgeMs: 0 });
  assert.equal(memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot }).state, 'fresh');
});

test('файлов памяти нет вообще → none-yet, НЕ stale', () => {
  const s = sandbox({ files: {}, txAgeMs: 0 });
  assert.equal(memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot }).state, 'none-yet');
});

test('brainPath пуст → n/a (воркер не brain-овый)', () => {
  assert.equal(memoryFreshness(null, 'sid', STALE_AFTER).state, 'n/a');
});

test('brainPath указан, но папки нет → path-missing (папку не воссоздаём)', () => {
  const r = memoryFreshness('/nonexistent/клиент', 'sid', STALE_AFTER);
  assert.equal(r.state, 'path-missing');
});

test('транскрипт не найден → не stale (нечего сравнивать)', () => {
  const s = sandbox({ files: { 'timeline.md': 40 * HOUR }, txAgeMs: 0 });
  const r = memoryFreshness(s.brain, 'нет-такой-сессии', STALE_AFTER, { projectsRoot: s.projectsRoot });
  assert.notEqual(r.state, 'stale');
  assert.equal(r.txMtimeMs, 0);
});

test('CLI отдаёт тот же JSON, что и модуль', () => {
  const s = sandbox({ files: { 'CLAUDE.md': 60_000 }, txAgeMs: 0 });
  const out = execFileSync(CLI, ['--brain-path', s.brain, '--session-id', s.sid, '--stale-after-secs', '1800'],
    { encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECTS_ROOT: s.projectsRoot } });
  const j = JSON.parse(out);
  assert.equal(j.state, 'fresh');
  assert.equal(j.newestFile, 'CLAUDE.md');
});

test('CLI: неизвестный/опечатанный флаг → exit 2, а не тихий n/a', () => {
  // Опечатка «--brain_path» не должна молча дать n/a и снять гард.
  for (const bad of [['--brain_path', '/tmp'], ['--нет-такого', 'x'], ['--brain-path']]) {
    assert.throws(() => execFileSync(CLI, bad, { encoding: 'utf8', stdio: 'pipe' }),
      (e) => e.status === 2, `флаги ${JSON.stringify(bad)} обязаны дать exit 2`);
  }
});

test('CLI: без --brain-path → exit 2 (обязательный аргумент)', () => {
  assert.throws(() => execFileSync(CLI, ['--session-id', 'x'], { encoding: 'utf8', stdio: 'pipe' }),
    (e) => e.status === 2);
});

test('MEMORY_GLOBS перечисляет манифест и префиксные имена (пин против тихого сужения списка)', () => {
  assert.ok(MEMORY_GLOBS.includes('CLAUDE.md'));
  assert.ok(MEMORY_GLOBS.some((g) => g.startsWith('timeline')));
  assert.ok(MEMORY_GLOBS.some((g) => g.startsWith('decisions')));
});

// --- ЯДРО: memoryFreshnessFromTx — сигнатура для dept-dispatcher (Codex крит. №1) ---

test('memoryFreshnessFromTx: принимает готовый txMtime (сигнатура диспетчера)', () => {
  const s = sandbox({ files: { 'CLAUDE.md': 40 * HOUR }, txAgeMs: 0 });
  const r = memoryFreshnessFromTx(s.brain, Date.now(), STALE_AFTER);
  assert.equal(r.state, 'stale');
});

test('memoryFreshness — тонкая обёртка над ядром: результаты совпадают', () => {
  const s = sandbox({ files: { 'timeline.md': 40 * HOUR }, txAgeMs: 0 });
  const viaSid = memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot });
  const viaTx = memoryFreshnessFromTx(s.brain, viaSid.txMtimeMs, STALE_AFTER);
  assert.deepEqual(viaTx, viaSid);
});

test('РЕГРЕСС-ГАРД: none-yet при ЖИВОМ транскрипте отдаёт txMtimeMs — вызыватель обязан отличить его от свежего воркера', () => {
  // claude-auto сегодня при mem_mtime=0 и живом транскрипте даёт die (разрыв tx-0 > порога).
  // Без txMtimeMs в ответе cmd_rebase не смог бы отличить «памяти нет, сессия живёт»
  // (блокировать) от «воркер только что создан» (пропустить) — и защита снялась бы молча.
  const s = sandbox({ files: {}, txAgeMs: 0 });
  const r = memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot });
  assert.equal(r.state, 'none-yet');
  assert.ok(r.txMtimeMs > 0, 'none-yet обязан нести txMtimeMs — по нему гард решает, блокировать ли rebase');
});

test('none-yet без транскрипта → txMtimeMs=0 (свежий воркер, rebase законен)', () => {
  const r = memoryFreshnessFromTx('/tmp', 0, STALE_AFTER);
  assert.equal(r.txMtimeMs, 0);
});

test('каталог с именем timeline* не считается файлом памяти (p3#21)', () => {
  const s = sandbox({ files: {}, txAgeMs: 0 });
  mkdirSync(join(s.brain, 'timeline-архив'), { recursive: true });
  assert.equal(memoryFreshness(s.brain, s.sid, STALE_AFTER, { projectsRoot: s.projectsRoot }).state, 'none-yet');
});
