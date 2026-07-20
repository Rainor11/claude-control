// tests/process-control.test.mjs — T2 (изоляция тестов от боевого рантайма, guard
// процесс-контроля). JS-сторона lib/process-control.js: см. .superpowers/sdd/iso-t2-brief.md.
// Переиспользует lib/runtime-root.js (resolveRuntimeRoot, contained) — не дублирует ни
// логику маркера, ни containment.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  mkdtempSync, writeFileSync, symlinkSync, chmodSync, readFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const require_ = createRequire(import.meta.url);
const {
  resolveProcessControlTestRoot, unitDirDecision, tmuxSocketArgv, systemdRunSetenvArgv,
  checkBinarySeam, preflight, unitDir, checkUnitDir,
} = require_('../lib/process-control.js');
const { MARKER_VAR } = require_('../lib/runtime-root.js');

const LIB_SH = fileURLToPath(new URL('../lib/process-control.sh', import.meta.url));
const FIXTURE_CASES = JSON.parse(
  readFileSync(fileURLToPath(new URL('./fixtures/process-control-cases.json', import.meta.url)), 'utf8'),
);

const fakeDir = (prefix) => mkdtempSync(join(tmpdir(), prefix));
const sentinelFile = (root) => writeFileSync(join(root, '.claude-control-test-root'), '');
const makeFakeBin = (p) => {
  writeFileSync(p, '#!/bin/bash\nexit 0\n');
  chmodSync(p, 0o755);
};

// resolvePureViaBash(fnName, args): гоняет ОДНУ chистую bash-функцию (уже source'нутую
// lib/process-control.sh) подпроцессом — паритет с tests/runtime-root.test.mjs
// resolveViaBash (T1, В2): кросс-проверка bash/js на ОДНОМ входе, не зеркалим таблицу
// кейсов руками между реализациями.
function resolvePureViaBash(fnName, args) {
  const out = execFileSync(
    'bash',
    ['-c', 'set -u; . "$1"; "$2" "${@:3}"', 'bash', LIB_SH, fnName, ...args],
    { env: { PATH: process.env.PATH || '/usr/bin:/bin', HOME: '/nonexistent-home-not-used-by-pure-fns' }, encoding: 'utf8' },
  );
  return out.replace(/\n$/, '').split('\n').filter((_, idx, arr) => !(idx === arr.length - 1 && arr[arr.length - 1] === ''));
}

// ---------------------------------------------------------------------------------------
// Фикстура — чистые функции решений, общая с bash-стороной (tests/process-control.test.sh
// гоняет ТУ ЖЕ таблицу через свой раннер).
// ---------------------------------------------------------------------------------------

for (const c of FIXTURE_CASES) {
  test(`fixture-паритет: ${c.name}`, () => {
    let jsResult;
    let bashFn;
    let bashArgs;
    // isScalar: unit_dir_decision печатает ОДНУ строку (каталог) — expect в фикстуре
    // плоская строка, не массив; tmux_socket_argv/systemd_run_setenv_argv печатают argv
    // (ноль/две строки) — expect массив.
    const isScalar = c.fn === 'unit_dir_decision';
    if (c.fn === 'unit_dir_decision') {
      jsResult = unitDirDecision(c.args.testRoot || null, c.args.home);
      bashFn = 'process_control_unit_dir_decision';
      bashArgs = [c.args.testRoot, c.args.home];
    } else if (c.fn === 'tmux_socket_argv') {
      jsResult = tmuxSocketArgv(c.args.name, c.args.testRoot || null);
      bashFn = 'process_control_tmux_socket_argv';
      bashArgs = [c.args.name, c.args.testRoot];
    } else if (c.fn === 'systemd_run_setenv_argv') {
      jsResult = systemdRunSetenvArgv(c.args.testRoot || null);
      bashFn = 'process_control_systemd_run_setenv_argv';
      bashArgs = [c.args.testRoot];
    } else {
      throw new Error(`неизвестная fn '${c.fn}' в фикстуре`);
    }

    assert.deepEqual(jsResult, c.expect, `js результат для '${c.name}'`);

    const bashLines = resolvePureViaBash(bashFn, bashArgs);
    // Пустой bash-массив: process_control_systemd_run_setenv_argv без маркера печатает НОЛЬ
    // строк — split('\n') на пустой строке даёт [''], нормализуем к [] для сравнения.
    const bashEmpty = bashLines.length === 1 && bashLines[0] === '';
    const bashResult = isScalar ? bashLines[0] : (bashEmpty ? [] : bashLines);
    assert.deepEqual(bashResult, c.expect, `bash результат для '${c.name}'`);
    assert.deepEqual(jsResult, bashResult, `js/bash разошлись для '${c.name}'`);
  });
}

// ---------------------------------------------------------------------------------------
// resolveProcessControlTestRoot — тонкая делегация в resolveRuntimeRoot (T1 уже покрыл
// fail-closed исчерпывающе, здесь только доказываем, что делегация работает).
// ---------------------------------------------------------------------------------------

test('resolveProcessControlTestRoot: без маркера — null', () => {
  const home = fakeDir('pc-home-');
  assert.equal(resolveProcessControlTestRoot({ HOME: home }), null);
});

test('resolveProcessControlTestRoot: валидный маркер — канонический test root', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const result = resolveProcessControlTestRoot({ HOME: home, [MARKER_VAR]: root });
  assert.equal(result, execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim());
});

test('resolveProcessControlTestRoot: маркер без sentinel — throw (делегировано resolveRuntimeRoot)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-'); // БЕЗ sentinel
  assert.throws(() => resolveProcessControlTestRoot({ HOME: home, [MARKER_VAR]: root }), /sentinel/);
});

// ---------------------------------------------------------------------------------------
// checkBinarySeam / preflight — под маркером без заглушки / заглушка вне root / заглушка
// внутри root / заглушка-симлинк наружу.
// ---------------------------------------------------------------------------------------

test('checkBinarySeam: без testRoot — не проверяет ничего (прод-путь)', () => {
  assert.doesNotThrow(() => checkBinarySeam('SYSTEMCTL', 'systemctl-not-a-real-command-xyz', null));
});

test('checkBinarySeam: под test root, seam не переопределён (дефолт "systemctl", реальный бинарь снаружи) — throw', () => {
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  assert.throws(() => checkBinarySeam('SYSTEMCTL', 'systemctl', root), /снаружи|не внутрь|не найден/);
});

test('checkBinarySeam: заглушка ВНУТРИ test root — не бросает', () => {
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-systemctl');
  makeFakeBin(stub);
  assert.doesNotThrow(() => checkBinarySeam('SYSTEMCTL', stub, root));
});

test('checkBinarySeam: заглушка ВНЕ test root (абсолютный путь) — throw', () => {
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const outsideDir = fakeDir('pc-outside-');
  const stub = join(outsideDir, 'fake-systemctl');
  makeFakeBin(stub);
  assert.throws(() => checkBinarySeam('SYSTEMCTL', stub, root), /снаружи|не внутрь/);
});

test('checkBinarySeam: заглушка-СИМЛИНК внутри test root на бинарь СНАРУЖИ — throw (defense-in-depth)', () => {
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const outsideDir = fakeDir('pc-outside-');
  const realStub = join(outsideDir, 'fake-systemctl-outside');
  makeFakeBin(realStub);
  const symlinkStub = join(root, 'systemctl-symlink');
  symlinkSync(realStub, symlinkStub);
  assert.throws(() => checkBinarySeam('SYSTEMCTL', symlinkStub, root), /снаружи|не внутрь/);
});

test('preflight: неизвестный класс — throw', () => {
  const home = fakeDir('pc-home-');
  assert.throws(() => preflight('bogus_class', { HOME: home }), /неизвестный класс/);
});

test('preflight: systemctl без маркера — не бросает (прод-путь)', () => {
  const home = fakeDir('pc-home-');
  assert.doesNotThrow(() => preflight('systemctl', { HOME: home, PATH: process.env.PATH }));
});

test('preflight: systemctl под маркером без переопределения — throw', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  assert.throws(
    () => preflight('systemctl', { HOME: home, [MARKER_VAR]: root, PATH: process.env.PATH }),
    /снаружи|не внутрь|не найден/,
  );
});

test('preflight: systemd_run под маркером с заглушкой внутри test root — не бросает', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-systemd-run');
  makeFakeBin(stub);
  assert.doesNotThrow(() => preflight('systemd_run', {
    HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub, PATH: process.env.PATH,
  }));
});

test('preflight: unit_dir — резолвится без ошибки (без маркера и под валидным маркером)', () => {
  const home = fakeDir('pc-home-');
  assert.doesNotThrow(() => preflight('unit_dir', { HOME: home }));
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  assert.doesNotThrow(() => preflight('unit_dir', { HOME: home, [MARKER_VAR]: root }));
});

// ---------------------------------------------------------------------------------------
// unitDir / checkUnitDir
// ---------------------------------------------------------------------------------------

test('unitDir: без маркера — реальный $HOME/.config/systemd/user', () => {
  const home = fakeDir('pc-home-');
  assert.equal(unitDir({ HOME: home }), `${home}/.config/systemd/user`);
});

test('unitDir: под маркером — <test_root>/systemd-user, НЕ реальный $HOME/.config/systemd/user', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const canonRoot = execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim();
  assert.equal(unitDir({ HOME: home, [MARKER_VAR]: root }), `${canonRoot}/systemd-user`);
});

test('checkUnitDir: без маркера — не проверяет ничего', () => {
  const home = fakeDir('pc-home-');
  assert.doesNotThrow(() => checkUnitDir('/any/random/dir', { HOME: home }));
});

test('checkUnitDir: каталог ВНЕ test root под маркером — throw', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const outside = fakeDir('pc-outside-');
  assert.throws(() => checkUnitDir(outside, { HOME: home, [MARKER_VAR]: root }), /снаружи/i);
});

test('checkUnitDir: каталог ВНУТРИ test root под маркером — не бросает', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const canonRoot = execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim();
  assert.doesNotThrow(() => checkUnitDir(`${canonRoot}/nested/unit-dir`, { HOME: home, [MARKER_VAR]: root }));
});
