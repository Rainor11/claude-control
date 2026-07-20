// tests/bootstrap.test.mjs — тесты tests/lib/bootstrap.mjs (T3, эквивалент
// tests/bootstrap.test.sh для .mjs-тестов). См. .superpowers/sdd/iso-t3-brief.md, рубеж 2:
// "запустили тест в обход раннера — маркер отсутствует/невалиден/заглушки не на месте →
// явный отказ ДО тела теста".
//
// Этот файл — НОВЫЙ тест T3, сам обязан подключать bootstrap первой строкой (см.
// lint-bootstrap.test.sh) — прямой запуск в обход tests/run откажет так же, как любой другой
// тест. Каждый СЦЕНАРИЙ ниже (маркер отсутствует/невалиден/заглушки частичные/полные) гоняет
// tests/lib/bootstrap.mjs в ОТДЕЛЬНОМ node-подпроцессе (не через прямой import() в этом же
// процессе) — ES-модули кэшируются, повторный import() в ОДНОМ процессе с другим env не
// перезапустил бы top-level код bootstrap.mjs второй раз.
import './lib/bootstrap.mjs';

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  mkdtempSync, mkdirSync, writeFileSync, chmodSync, symlinkSync, rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const { SENTINEL_NAME } = createRequire(import.meta.url)('../lib/runtime-root.js');
const BOOTSTRAP_PATH = fileURLToPath(new URL('./lib/bootstrap.mjs', import.meta.url));

function makeStub(path) {
  writeFileSync(path, '#!/bin/bash\nexit 0\n');
  chmodSync(path, 0o755);
}

// fullSandbox(): полностью валидная песочница (sentinel + 3 заглушки process-control),
// возвращает путь к корню.
function fullSandbox() {
  const root = mkdtempSync(join(tmpdir(), 'bootstrap-mjs-'));
  writeFileSync(join(root, SENTINEL_NAME), '');
  const stubs = join(root, 'stubs');
  mkdirSync(stubs);
  makeStub(join(stubs, 'systemctl'));
  makeStub(join(stubs, 'systemd-run'));
  makeStub(join(stubs, 'tmux'));
  return root;
}

// runBootstrap(env): импортирует tests/lib/bootstrap.mjs В ОТДЕЛЬНОМ node-подпроцессе с
// заданным env (ПОЛНОСТЬЮ заменяет environment — тот же паттерн изоляции, что
// tests/runtime-root.test.mjs::resolveViaBash). На успехе подпроцесс печатает "REACHED" в
// stdout (доказывает, что тело "теста" ПОСЛЕ bootstrap реально выполнилось бы) — на отказе
// bootstrap.mjs сам вызывает process.exit(1) до этой строки.
function runBootstrap(env) {
  // HOME наследуем от ВНЕШНЕГО процесса (тот, в котором гоняется этот .mjs-тест — реальный
  // раннер задаёт его сам, см. tests/run) — resolveRuntimeRoot ТРЕБУЕТ HOME даже под
  // маркером (проверка "test root не совпадает с HOME"), и ни один из сконструированных
  // ниже test root не совпадает с внешним HOME, так что коллизии нет ни в одном сценарии.
  const childEnv = {
    PATH: process.env.PATH || '/usr/bin:/bin',
    HOME: process.env.HOME || '/nonexistent-home-not-used-by-bootstrap-tests',
    ...env,
  };
  const res = spawnSync(
    process.execPath,
    ['-e', "import(process.argv[1]).then(() => { process.stdout.write('REACHED\\n'); });", '--', BOOTSTRAP_PATH],
    { env: childEnv, encoding: 'utf8' },
  );
  return { status: res.status, stdout: res.stdout || '', stderr: res.stderr || '' };
}

test('без маркера — явный отказ, тело теста не выполняется', () => {
  const { status, stdout, stderr } = runBootstrap({});
  assert.notEqual(status, 0, `без маркера обязан отказать: ${stdout}${stderr}`);
  assert.doesNotMatch(stdout, /REACHED/, 'тело теста выполнилось несмотря на отказ');
  assert.match(stderr, /CLAUDE_CONTROL_TEST_ROOT/, 'сообщение не называет маркер');
  assert.match(stderr, /tests\/run/, 'сообщение не подсказывает запустить через tests/run');
});

test('маркер невалиден (нет sentinel) — отказ делегирован T1', () => {
  const root = mkdtempSync(join(tmpdir(), 'bootstrap-mjs-nosentinel-'));
  try {
    const { status, stdout, stderr } = runBootstrap({ CLAUDE_CONTROL_TEST_ROOT: root });
    assert.notEqual(status, 0, `маркер без sentinel обязан отказать: ${stdout}${stderr}`);
    assert.doesNotMatch(stdout, /REACHED/);
    assert.match(stderr, /sentinel/i, 'сообщение не упоминает sentinel');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('валидный test root без заглушек — отказ делегирован T2 preflight (класс systemctl первый)', () => {
  const root = mkdtempSync(join(tmpdir(), 'bootstrap-mjs-nostubs-'));
  writeFileSync(join(root, SENTINEL_NAME), '');
  try {
    const { status, stdout, stderr } = runBootstrap({ CLAUDE_CONTROL_TEST_ROOT: root });
    assert.notEqual(status, 0, `test root без заглушек обязан отказать: ${stdout}${stderr}`);
    assert.doesNotMatch(stdout, /REACHED/);
    assert.match(stderr, /systemctl/, 'сообщение не называет класс systemctl');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('частичные заглушки (только SYSTEMCTL) — отказ на первом недостающем классе', () => {
  const root = mkdtempSync(join(tmpdir(), 'bootstrap-mjs-partial-'));
  writeFileSync(join(root, SENTINEL_NAME), '');
  const stubs = join(root, 'stubs');
  mkdirSync(stubs);
  makeStub(join(stubs, 'systemctl'));
  try {
    const { status, stdout, stderr } = runBootstrap({
      CLAUDE_CONTROL_TEST_ROOT: root,
      SYSTEMCTL: join(stubs, 'systemctl'),
    });
    assert.notEqual(status, 0, `частичные заглушки обязаны отказать: ${stdout}${stderr}`);
    assert.doesNotMatch(stdout, /REACHED/);
    assert.match(stderr, /systemd_run/, 'сообщение не называет недостающий класс systemd_run');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('счастливый путь — маркер + sentinel + все 3 заглушки → bootstrap пропускает', () => {
  const root = fullSandbox();
  try {
    const { status, stdout, stderr } = runBootstrap({
      CLAUDE_CONTROL_TEST_ROOT: root,
      SYSTEMCTL: join(root, 'stubs', 'systemctl'),
      DEPT_SYSTEMD_RUN: join(root, 'stubs', 'systemd-run'),
      TMUX_BIN: join(root, 'stubs', 'tmux'),
    });
    assert.equal(status, 0, `полностью валидная песочница обязана пройти: ${stdout}${stderr}`);
    assert.match(stdout, /REACHED/, 'тело теста после bootstrap не выполнилось');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('заглушка-симлинк на бинарь СНАРУЖИ test root — отказ (делегировано T2 checkBinarySeam)', () => {
  const root = mkdtempSync(join(tmpdir(), 'bootstrap-mjs-symlink-'));
  writeFileSync(join(root, SENTINEL_NAME), '');
  const stubs = join(root, 'stubs');
  mkdirSync(stubs);
  makeStub(join(stubs, 'systemd-run'));
  makeStub(join(stubs, 'tmux'));
  const outsideDir = mkdtempSync(join(tmpdir(), 'bootstrap-mjs-outside-'));
  const realLike = join(outsideDir, 'real-like-systemctl');
  makeStub(realLike);
  symlinkSync(realLike, join(stubs, 'systemctl'));
  try {
    const { status, stdout, stderr } = runBootstrap({
      CLAUDE_CONTROL_TEST_ROOT: root,
      SYSTEMCTL: join(stubs, 'systemctl'),
      DEPT_SYSTEMD_RUN: join(stubs, 'systemd-run'),
      TMUX_BIN: join(stubs, 'tmux'),
    });
    assert.notEqual(status, 0, `заглушка-симлинк наружу test root обязана отказать: ${stdout}${stderr}`);
    assert.doesNotMatch(stdout, /REACHED/);
    assert.match(stderr, /systemctl/, 'сообщение не называет класс systemctl');
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(outsideDir, { recursive: true, force: true });
  }
});
