// tests/runtime-root.test.mjs — T1 (изоляция тестов от боевого рантайма). Резолвер
// заменяет 24 копии инлайновой логики CONTROL_DIR/DEPT_HOME с ТРЕМЯ разными порядками
// приоритета (см. .superpowers/sdd/iso-t1-brief.md) — без него тестовый прогон не имеет
// механической границы от боевого флота (см. инцидент 20.07: испорченная переменная
// окружения утекла в claude-auto@.service). resolveRuntimeRoot — единственное место,
// где решение "отказать" под тестовым маркером принимается: fail-closed по умолчанию.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, symlinkSync, writeFileSync, realpathSync, mkdirSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const { resolveRuntimeRoot, PROFILES, SENTINEL_NAME, HARDCODED_PROD_CONTROL_DIR } =
  createRequire(import.meta.url)('../lib/runtime-root.js');

const fakeHome = () => mkdtempSync(join(tmpdir(), 'rr-home-'));
const fakeRoot = () => mkdtempSync(join(tmpdir(), 'rr-root-'));
const sentinel = (root) => writeFileSync(join(root, SENTINEL_NAME), '');

// ---------------------------------------------------------------------------
// Паритет с сегодняшним кодом (БЕЗ маркера) — построчно по таблице профилей брифа.
// Каждое ожидаемое значение процитировано с точным file:line, сверенным grep'ом
// перед написанием этого теста (не с таблицы брифа на слово — она сама предупреждает,
// что первоисточник это код).
// ---------------------------------------------------------------------------

test('control_only паритет: CONTROL_DIR="${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}" (bin/claude-auto:49, bin/claude-auto-run:21, +15 др.)', () => {
  const home = fakeHome();
  // без CLAUDE_CONTROL_DIR — дефолт $HOME/.claude-control
  assert.equal(
    resolveRuntimeRoot('control_only', { HOME: home }),
    join(home, '.claude-control'),
  );
  // с CLAUDE_CONTROL_DIR — он и побеждает
  assert.equal(
    resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_DIR: '/custom/dir' }),
    '/custom/dir',
  );
});

test('control_only: пустая строка CLAUDE_CONTROL_DIR="" — bash ${VAR:-default} считает это "не задано", резолвер обязан повторить', () => {
  const home = fakeHome();
  assert.equal(
    resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_DIR: '' }),
    join(home, '.claude-control'),
  );
});

test('auto_then_control паритет: CONTROL_DIR="${CLAUDE_AUTO_HOME:-${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}}" (bin/dept-liveness-exec:24, bin/dept-liveness-request:33)', () => {
  const home = fakeHome();
  assert.equal(
    resolveRuntimeRoot('auto_then_control', { HOME: home }),
    join(home, '.claude-control'),
  );
  assert.equal(
    resolveRuntimeRoot('auto_then_control', { HOME: home, CLAUDE_CONTROL_DIR: '/custom/dir' }),
    '/custom/dir',
  );
  // CLAUDE_AUTO_HOME побеждает CLAUDE_CONTROL_DIR — в отличие от control_only, тут есть
  // более высокий приоритет
  assert.equal(
    resolveRuntimeRoot('auto_then_control', {
      HOME: home, CLAUDE_CONTROL_DIR: '/custom/dir', CLAUDE_AUTO_HOME: '/auto/dir',
    }),
    '/auto/dir',
  );
});

test('auto_then_hardcoded паритет: const CC_HOME = process.env.CLAUDE_AUTO_HOME || \'/home/rainor/.claude-control\' (bin/claude-auto-liveness:14, bin/dept-inbox:16, bin/dept-rebase-check:16, bin/dept-dispatcher:153)', () => {
  const home = fakeHome();
  // без CLAUDE_AUTO_HOME — ЛИТЕРАЛЬНЫЙ хардкод, НЕ $HOME-based (даже если HOME другой)
  assert.equal(resolveRuntimeRoot('auto_then_hardcoded', { HOME: home }), HARDCODED_PROD_CONTROL_DIR);
  assert.equal(HARDCODED_PROD_CONTROL_DIR, '/home/rainor/.claude-control');
  // CLAUDE_CONTROL_DIR ИГНОРИРУЕТСЯ этим профилем — ключевое отличие от auto_then_control
  assert.equal(
    resolveRuntimeRoot('auto_then_hardcoded', { HOME: home, CLAUDE_CONTROL_DIR: '/custom/dir' }),
    HARDCODED_PROD_CONTROL_DIR,
  );
  assert.equal(
    resolveRuntimeRoot('auto_then_hardcoded', { HOME: home, CLAUDE_AUTO_HOME: '/auto/dir' }),
    '/auto/dir',
  );
});

test('dept_only паритет: DEPT="${DEPT_HOME:-$HOME/.claude-control/department}" (bin/dept-mission-exec:20, bin/dept-exec-runner:28, bin/dept-spawn-exec:17)', () => {
  const home = fakeHome();
  assert.equal(
    resolveRuntimeRoot('dept_only', { HOME: home }),
    join(home, '.claude-control', 'department'),
  );
  assert.equal(
    resolveRuntimeRoot('dept_only', { HOME: home, DEPT_HOME: '/custom/dept' }),
    '/custom/dept',
  );
  // dept_only ИГНОРИРУЕТ CLAUDE_AUTO_HOME/CLAUDE_CONTROL_DIR целиком — реальный код этих
  // трёх файлов не читает ни ту, ни другую переменную при вычислении DEPT
  assert.equal(
    resolveRuntimeRoot('dept_only', {
      HOME: home, CLAUDE_AUTO_HOME: '/auto/dir', CLAUDE_CONTROL_DIR: '/custom/dir',
    }),
    join(home, '.claude-control', 'department'),
  );
});

test('неизвестный профиль — отказ с понятным текстом', () => {
  assert.throws(() => resolveRuntimeRoot('bogus', { HOME: fakeHome() }), /профил/i);
});

test('без HOME — отказ (резолвер не может вычислить боевой дефолт)', () => {
  assert.throws(() => resolveRuntimeRoot('control_only', {}), /HOME/);
});

// ---------------------------------------------------------------------------
// Маркер CLAUDE_CONTROL_TEST_ROOT — happy path
// ---------------------------------------------------------------------------

test('маркер: control_only/auto_then_control/auto_then_hardcoded возвращают сам test root', () => {
  const home = fakeHome();
  const root = fakeRoot();
  sentinel(root);
  for (const profile of ['control_only', 'auto_then_control', 'auto_then_hardcoded']) {
    assert.equal(
      resolveRuntimeRoot(profile, { HOME: home, CLAUDE_CONTROL_TEST_ROOT: root }),
      realpathSync(root),
    );
  }
});

test('маркер: dept_only возвращает test_root/department', () => {
  const home = fakeHome();
  const root = fakeRoot();
  sentinel(root);
  assert.equal(
    resolveRuntimeRoot('dept_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: root }),
    join(realpathSync(root), 'department'),
  );
});

test('маркер: путь через symlink канонизируется (realpath), возвращается реальный путь', () => {
  const home = fakeHome();
  const real = fakeRoot();
  sentinel(real);
  const link = join(tmpdir(), `rr-link-${process.pid}-${Date.now()}`);
  symlinkSync(real, link);
  try {
    assert.equal(
      resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: link }),
      realpathSync(real),
    );
  } finally {
    unlinkSync(link);
  }
});

test('маркер: пустая строка CLAUDE_CONTROL_TEST_ROOT="" — как будто маркер не задан (легаси-путь)', () => {
  const home = fakeHome();
  assert.equal(
    resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: '' }),
    join(home, '.claude-control'),
  );
});

// ---------------------------------------------------------------------------
// Маркер — негативные кейсы (ядро задачи: fail-closed)
// ---------------------------------------------------------------------------

test('маркер без sentinel-файла — отказ', () => {
  const home = fakeHome();
  const root = fakeRoot(); // БЕЗ sentinel
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: root }),
    /sentinel/,
  );
});

test('маркер — относительный путь — отказ', () => {
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: 'relative/path' }),
    /абсолютн/,
  );
});

test('маркер — несуществующий путь — отказ', () => {
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: '/no/such/path/at/all' }),
    /не резолвится|не существует/,
  );
});

test('маркер = "/" — отказ', () => {
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: '/' }),
    /корн[её]м файловой системы/,
  );
});

test('маркер = $HOME — отказ (слишком широкий охват)', () => {
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: home }),
    /домашн/,
  );
});

test('маркер: несуществующий (dangling) $HOME — отказ, а не тихий пропуск проверки на совпадение', () => {
  const root = fakeRoot();
  sentinel(root);
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: '/no/such/home/at/all', CLAUDE_CONTROL_TEST_ROOT: root }),
    /HOME/,
  );
});

test('маркер = боевой $HOME/.claude-control — отказ', () => {
  const home = fakeHome();
  const prod = join(home, '.claude-control');
  mkdirSync(prod);
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: prod }),
    /боев/,
  );
});

test('маркер = захардкоженный боевой корень /home/rainor/.claude-control — отказ (только realpath, без записи)', () => {
  // ЖИВОЙ каталог на этом сервере — резолвер обязан заблокировать буквальный литерал
  // auto_then_hardcoded профиля, даже если HOME указывает на другое место. Только
  // fs.realpathSync (read-only stat), никакой записи/чтения содержимого.
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: HARDCODED_PROD_CONTROL_DIR }),
    /боев/,
  );
});

test('маркер + легаси-переменная указывает НАРУЖУ test root — отказ, а не тихий приоритет', () => {
  const home = fakeHome();
  const root = fakeRoot();
  sentinel(root);
  const outside = fakeRoot();
  assert.throws(
    () => resolveRuntimeRoot('control_only', {
      HOME: home, CLAUDE_CONTROL_TEST_ROOT: root, CLAUDE_CONTROL_DIR: outside,
    }),
    /CLAUDE_CONTROL_DIR/,
  );
});

test('маркер + легаси-переменная указывает ВНУТРЬ test root — ОК, не отказ', () => {
  const home = fakeHome();
  const root = fakeRoot();
  sentinel(root);
  const inside = join(root, 'sub');
  mkdirSync(inside);
  assert.equal(
    resolveRuntimeRoot('control_only', {
      HOME: home, CLAUDE_CONTROL_TEST_ROOT: root, CLAUDE_CONTROL_DIR: inside,
    }),
    realpathSync(root),
  );
});

test('containment — НЕ голый строковый префикс: /tmp/xxx-prod не должен пройти как "подкаталог" /tmp/xxx', () => {
  const home = fakeHome();
  const base = fakeRoot();
  const root = join(base, 'root');
  const sibling = join(base, 'root-prod'); // текстовый префикс совпадает с root, но НЕ подкаталог
  mkdirSync(root);
  mkdirSync(sibling);
  sentinel(root);
  assert.throws(
    () => resolveRuntimeRoot('control_only', {
      HOME: home, CLAUDE_CONTROL_TEST_ROOT: root, CLAUDE_CONTROL_DIR: sibling,
    }),
    /CLAUDE_CONTROL_DIR/,
  );
});

test('".." в легаси-переменной, резолвящийся ЗА пределы test root через realpath — отказ', () => {
  const home = fakeHome();
  const base = fakeRoot();
  const root = join(base, 'inner');
  const outside = join(base, 'outside');
  mkdirSync(root);
  mkdirSync(outside);
  sentinel(root);
  const escaping = join(root, '..', 'outside'); // текстово "внутри", после realpath — снаружи
  assert.throws(
    () => resolveRuntimeRoot('dept_only', {
      HOME: home, CLAUDE_CONTROL_TEST_ROOT: root, DEPT_HOME: escaping,
    }),
    /DEPT_HOME/,
  );
});

test('маркер + недостижимая легаси-переменная (несуществующий путь) — отказ с внятным текстом', () => {
  const home = fakeHome();
  const root = fakeRoot();
  sentinel(root);
  assert.throws(
    () => resolveRuntimeRoot('auto_then_hardcoded', {
      HOME: home, CLAUDE_CONTROL_TEST_ROOT: root, CLAUDE_AUTO_HOME: '/no/such/leftover/path',
    }),
    /CLAUDE_AUTO_HOME/,
  );
});

test('все 4 профиля объявлены в PROFILES', () => {
  assert.deepEqual(
    [...PROFILES].sort(),
    ['auto_then_control', 'auto_then_hardcoded', 'control_only', 'dept_only'].sort(),
  );
});
