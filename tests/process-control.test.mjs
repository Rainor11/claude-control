// tests/process-control.test.mjs — T2 (изоляция тестов от боевого рантайма, guard
// процесс-контроля). JS-сторона lib/process-control.js: см. .superpowers/sdd/iso-t2-brief.md.
// Переиспользует lib/runtime-root.js (resolveRuntimeRoot, contained) — не дублирует ни
// логику маркера, ни containment.
// T6: обязательный пролог изоляции — первой значимой строкой файла. Сами сценарии
// ниже передают корни/швы ЯВНЫМИ аргументами (checkBinarySeam(var, value, root),
// preflight(cls, env)), поэтому подставленные раннером SYSTEMCTL/TMUX_BIN/
// DEPT_SYSTEMD_RUN на них не влияют — в отличие от bash-стороны, где их пришлось
// гасить (см. tests/process-control.test.sh).
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  mkdtempSync, mkdirSync, writeFileSync, symlinkSync, chmodSync, readFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const require_ = createRequire(import.meta.url);
const {
  resolveProcessControlTestRoot, unitDirDecision, tmuxSocketArgv, systemdRunSetenvArgv,
  checkBinarySeam, preflight, unitDir, checkUnitDir, realpathM, tmuxArgv, systemdRunArgv,
  resolveExecutablePath, BINARY_SEAM_DEFAULTS,
} = require_('../lib/process-control.js');
const { MARKER_VAR } = require_('../lib/runtime-root.js');

const LIB_SH = fileURLToPath(new URL('../lib/process-control.sh', import.meta.url));
const FIXTURE_CASES = JSON.parse(
  readFileSync(fileURLToPath(new URL('./fixtures/process-control-cases.json', import.meta.url)), 'utf8'),
);
const SEAM_CLASS_FIXTURE = JSON.parse(
  readFileSync(fileURLToPath(new URL('./fixtures/process-control-binary-seam-classes.json', import.meta.url)), 'utf8'),
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

// ---------------------------------------------------------------------------------------
// В6 (Codex-аудит, финальное ревью изоляции T1-T7): ловушка арности — третий аргумент
// (testRootOrNull) НЕ ПЕРЕДАН вовсе (в отличие от явного `null`, легитимно означающего
// "маркер не задан") обязан быть явным отказом, а не тем же fail-open, что у `null`.
// Bash-сторона (process_control_check_binary_seam) — двухаргументная, сама резолвит корень;
// мигрант, скопировавший этот вызов на JS "по аналогии" (2 аргумента), раньше молча получал
// пропуск проверки под маркером.
// ---------------------------------------------------------------------------------------

test('checkBinarySeam: третий аргумент НЕ передан (arity trap) — throw, НЕ тихий пропуск (В6)', () => {
  assert.throws(
    () => checkBinarySeam('SYSTEMCTL', 'systemctl'),
    /третий аргумент|ловушка арности/i,
  );
});

test('checkBinarySeam: явный null (легитимное "маркер не задан") — по-прежнему НЕ throw (В6, без ложных срабатываний)', () => {
  assert.doesNotThrow(() => checkBinarySeam('SYSTEMCTL', 'systemctl-not-a-real-command-xyz', null));
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

// ---------------------------------------------------------------------------------------
// К1 (ревью T2): checkUnitDir/realpathM обязаны разыменовывать симлинки СУЩЕСТВУЮЩЕГО
// префикса пути (аналог bash `realpath -m`) — было: `path.resolve` (чисто лексический), из-за
// чего симлинк ВНУТРИ test root, указывающий на каталог СНАРУЖИ, лексически "выглядел" как
// путь внутри root и containment-проверка пропускала побег. Это НЕ гипотетика — ровно вектор
// инцидента 20.07 (запись через путь, резолвящийся наружу test root).
// ---------------------------------------------------------------------------------------

test('realpathM: разыменовывает симлинк СУЩЕСТВУЮЩЕГО префикса, остаток дописывает литералом (аналог realpath -m)', () => {
  const root = fakeDir('pc-root-');
  const outside = fakeDir('pc-outside-');
  const link = join(root, 'unitlink');
  symlinkSync(outside, link);
  const canonOutside = execFileSync('realpath', ['-e', outside], { encoding: 'utf8' }).trim();
  assert.equal(realpathM(join(link, 'nested', 'dir')), join(canonOutside, 'nested', 'dir'));
});

test('checkUnitDir: симлинк ВНУТРИ test root, указывающий на каталог СНАРУЖИ — throw (К1)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const outside = fakeDir('pc-outside-');
  const link = join(root, 'unitlink');
  symlinkSync(outside, link);
  assert.throws(
    () => checkUnitDir(join(link, 'nested', 'unit-dir'), { HOME: home, [MARKER_VAR]: root }),
    /снаружи/i,
  );
});

// ---------------------------------------------------------------------------------------
// ДЕФЕКТ 1 (повторное ревью T2): realpathM/checkUnitDir обязаны разыменовывать БИТЫЙ
// (dangling) симлинк — цель которого НЕ существует — а не только симлинк на существующий
// каталог (кейс К1 выше). Старая realpathM звала fs.realpathSync(current) целиком и ловила
// ENOENT одинаково что для "компонента нет вовсе", что для "симлинк с несуществующей целью"
// — во втором случае она НИКОГДА не читала сам симлинк через readlink, и containment видел
// чисто лексический путь внутри test root, хотя симлинк реально вёл наружу. Все кейсы ниже
// сверены с фактическим поведением GNU `realpath -m` (не гипотеза, реальный запуск бинаря).
// ---------------------------------------------------------------------------------------

test('realpathM: битый симлинк (цель НЕ существует) наружу — разыменовывается через readlink, не как "компонента нет" (Дефект 1)', () => {
  const root = fakeDir('pc-root-');
  const outsideMissing = join(fakeDir('pc-outside-'), 'never-created-xyz');
  const link = join(root, 'danglink');
  symlinkSync(outsideMissing, link); // цель НЕ существует — symlinkSync это не проверяет
  assert.equal(realpathM(join(link, 'foo', 'bar')), join(outsideMissing, 'foo', 'bar'));
});

test('checkUnitDir: битый симлинк ВНУТРИ test root, указывающий НАРУЖУ (несуществующий путь) — throw (Дефект 1)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const outsideMissing = join(fakeDir('pc-outside-'), 'never-created-xyz');
  const link = join(root, 'danglink');
  symlinkSync(outsideMissing, link);
  assert.throws(
    () => checkUnitDir(join(link, 'foo', 'bar'), { HOME: home, [MARKER_VAR]: root }),
    /снаружи/i,
  );
});

test('checkUnitDir: битый симлинк ВНУТРИ test root, указывающий ВНУТРЬ (несуществующий путь) — не throw (Дефект 1, без ложных срабатываний)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const link = join(root, 'danglink-inside');
  symlinkSync(join(root, 'never-created-nested'), link); // цель внутри root, но не существует
  assert.doesNotThrow(
    () => checkUnitDir(join(link, 'foo', 'bar'), { HOME: home, [MARKER_VAR]: root }),
  );
});

test('realpathM: цепочка симлинков, ПОСЛЕДНИЙ битый — резолвится сквозь ВСЮ цепочку до конца (Дефект 1)', () => {
  const root = fakeDir('pc-root-');
  const outsideMissing = join(fakeDir('pc-outside-'), 'never-created-final-xyz');
  const link2 = join(root, 'chain2');
  const link1 = join(root, 'chain1');
  symlinkSync(outsideMissing, link2); // chain2 -> /outside/never-created-final-xyz (битый)
  symlinkSync(link2, link1); // chain1 -> chain2
  assert.equal(realpathM(join(link1, 'tail')), join(outsideMissing, 'tail'));
});

test('realpathM: симлинк-цикл — НЕ виснет, возвращает путь без дальнейшего резолва (паритет с GNU realpath -m, Дефект 1)', { timeout: 5000 }, () => {
  const root = fakeDir('pc-root-');
  const cycA = join(root, 'cyc_a');
  const cycB = join(root, 'cyc_b');
  symlinkSync(cycB, cycA);
  symlinkSync(cycA, cycB);
  // GNU `realpath -m` на таком цикле (сверено фактическим запуском) возвращает путь БЕЗ
  // резолва (rc=0), не виснет и не бросает — здесь достаточно, что вызов вообще завершается
  // (timeout выше) и не бросает исключение.
  assert.doesNotThrow(() => realpathM(join(cycA, 'tail')));
});

// ---------------------------------------------------------------------------------------
// В5 (Codex-аудит, финальное ревью изоляции T1-T7): realpathM/checkUnitDir абсолютизировали
// вход через `path.resolve()`, который схлопывает ".." ЛЕКСИЧЕСКИ ДО обхода по компонентам —
// симлинк ВНУТРИ test root, указывающий НАРУЖУ, + буквальный ".." В ЗАПРОСЕ ПОСЛЕ симлинка
// давал "выглядит внутри root" вместо физического резолва (см. "ДЕФЕКТ 2" в
// lib/process-control.js). Репро ревьюера: `checkUnitDir("<root>/link/../escape")` было
// APPROVED, bash-сторона (`realpath -m`, реальный бинарь) REJECTED. ВАЖНО: входной путь
// собираем БУКВАЛЬНОЙ КОНКАТЕНАЦИЕЙ строк (`` `${link}/../escape` ``), НЕ через `join()` —
// `path.join()` САМ схлопнул бы ".." ДО вызова realpathM, и тест проходил бы вслепую, никогда
// не поймав Дефект 2 (та же ошибка была поймана в диф-фазз-харнессе при верификации фикса —
// первая версия харнесса использовала `path.join(base, case)` и получала 0 расхождений
// ЛОЖНО, см. отчёт).
// ---------------------------------------------------------------------------------------

test('realpathM: симлинк ВНУТРИ test root наружу + ".." В ЗАПРОСЕ ПОСЛЕ симлинка — резолвится ФИЗИЧЕСКИ, как GNU realpath -m, не лексически (В5, Дефект 2)', () => {
  const root = fakeDir('pc-root-');
  const outside = fakeDir('pc-outside-');
  const link = join(root, 'link');
  symlinkSync(outside, link);
  const rawInput = `${link}/../escape`;
  const viaRealBinary = execFileSync('realpath', ['-m', '--', rawInput], { encoding: 'utf8' }).trim();
  // Sanity: сценарий реально уходит НАРУЖУ и symlink-цели, и root (иначе тест был бы про
  // что-то другое, не про побег) — не ".../root/escape", не ".../outside/escape".
  assert.notEqual(viaRealBinary, join(root, 'escape'));
  assert.equal(realpathM(rawInput), viaRealBinary);
});

test('checkUnitDir: симлинк ВНУТРИ test root наружу + ".." В ЗАПРОСЕ ПОСЛЕ симлинка — throw (было APPROVED до фикса Дефекта 2, В5, точный репро ревьюера)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const outside = fakeDir('pc-outside-');
  const link = join(root, 'link');
  symlinkSync(outside, link);
  const rawInput = `${link}/../escape`;
  assert.throws(
    () => checkUnitDir(rawInput, { HOME: home, [MARKER_VAR]: root }),
    /снаружи/i,
  );
});

test('realpathM: батарея кейсов ".." после симлинка/несуществующего компонента/двойного слэша — паритет с GNU realpath -m (В5, Дефект 2)', () => {
  const root = fakeDir('pc-root-');
  mkdirSync(join(root, 'a', 'b'), { recursive: true });
  const outside = fakeDir('pc-outside-');
  symlinkSync(outside, join(root, 'a', 'linkabs'));
  const cases = [
    `${root}/a/b/../../a`,
    `${root}/a/linkabs/../x`,
    `${root}/a/doesnotexist/../y`,
    `${root}/a//b//../c`,
  ];
  for (const rawInput of cases) {
    const expected = execFileSync('realpath', ['-m', '--', rawInput], { encoding: 'utf8' }).trim();
    assert.equal(realpathM(rawInput), expected, rawInput);
  }
});

// ---------------------------------------------------------------------------------------
// В3 (ревью T2): unitDirDecision/unitDir — HOME НЕ ПЕРЕДАН (undefined/null в env-объекте, не
// просто пустая строка) обязан трактоваться как '' (паритет с bash `${HOME:-}`), а НЕ давать
// буквальное "undefined/.config/systemd/user" (JS `${undefined}` в шаблонной строке).
// ---------------------------------------------------------------------------------------

test('unitDirDecision: HOME=undefined без маркера — "/.config/systemd/user", НЕ "undefined/..." (В3)', () => {
  assert.equal(unitDirDecision(null, undefined), '/.config/systemd/user');
  assert.equal(unitDirDecision(null, null), '/.config/systemd/user');
});

test('unitDir: env без ключа HOME вовсе, без маркера — "/.config/systemd/user" (В3)', () => {
  assert.equal(unitDir({}), '/.config/systemd/user');
});

// ---------------------------------------------------------------------------------------
// В4 (ревью T2): resolveExecutablePath/checkBinarySeam — КАТАЛОГ (X_OK истинно и для него,
// нужен для traversal) НЕ обязан резолвиться как исполняемый файл. Bash `command -v` каталог
// не принимает (проверено: `command -v /tmp` → rc=1) — JS обязан повторить это, иначе preflight
// пропустит шов, указывающий на каталог, и вызывающий узнает об ошибке только на реальном exec.
// ---------------------------------------------------------------------------------------

test('resolveExecutablePath: каталог НЕ резолвится как исполняемый файл (В4)', () => {
  const dir = fakeDir('pc-dirseam-');
  assert.equal(resolveExecutablePath(dir), null);
});

test('checkBinarySeam: заглушка — КАТАЛОГ внутри test root — throw, не "успех" (В4)', () => {
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const dirSeam = join(root, 'dir-not-a-binary');
  mkdirSync(dirSeam);
  assert.throws(() => checkBinarySeam('SYSTEMCTL', dirSeam, root), /не найден/);
});

// ---------------------------------------------------------------------------------------
// В2 (ревью T2): BINARY_SEAM_DEFAULTS обязан совпадать с общей фикстурой
// tests/fixtures/process-control-binary-seam-classes.json (та же фикстура кросс-проверяется
// bash-стороной в tests/process-control.test.sh) — если завтра одна сторона переименует
// переменную/дефолт для класса, а другая нет, оба теста (bash и js) должны покраснеть, а не
// остаться молча зелёными по отдельности.
// ---------------------------------------------------------------------------------------

for (const seamCase of SEAM_CLASS_FIXTURE) {
  test(`BINARY_SEAM_DEFAULTS паритет с фикстурой: ${seamCase.class}`, () => {
    assert.deepEqual(BINARY_SEAM_DEFAULTS[seamCase.class], [seamCase.varName, seamCase.defaultBin]);
  });

  test(`preflight подхватывает заглушку под varName из фикстуры: ${seamCase.class}`, () => {
    const home = fakeDir('pc-home-');
    const root = fakeDir('pc-root-');
    sentinelFile(root);
    const stub = join(root, `fixture-seam-${seamCase.class}`);
    makeFakeBin(stub);
    const env = { HOME: home, [MARKER_VAR]: root, [seamCase.varName]: stub };
    assert.doesNotThrow(() => preflight(seamCase.class, env));
  });
}

// ---------------------------------------------------------------------------------------
// В5 (ревью T2): tmuxArgv/systemdRunArgv — СБОРЩИКИ готового argv для будущего T4-вызывающего
// (JS до этого фикса имел только preflight как единственную защиту — забыть примешать
// tmuxSocketArgv/systemdRunSetenvArgv в реальный вызов было физически возможно).
// ---------------------------------------------------------------------------------------

test('tmuxArgv: без маркера — [-L, claude-<name>] перед argv вызывающего', () => {
  const home = fakeDir('pc-home-');
  assert.deepEqual(
    tmuxArgv('workerA', ['kill-session'], { HOME: home, PATH: process.env.PATH }),
    { bin: 'tmux', argv: ['-L', 'claude-workerA', 'kill-session'] },
  );
});

test('tmuxArgv: под маркером — [-S, <root>/tmux.sock] + резолвленный TMUX_BIN', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-tmux');
  makeFakeBin(stub);
  const canonRoot = execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim();
  assert.deepEqual(
    tmuxArgv('workerA', ['kill-session'], { HOME: home, [MARKER_VAR]: root, TMUX_BIN: stub }),
    { bin: stub, argv: ['-S', `${canonRoot}/tmux.sock`, 'kill-session'] },
  );
});

test('tmuxArgv: имя со встроенным \\n — throw (паритет с bash-валидацией К2)', () => {
  const home = fakeDir('pc-home-');
  assert.throws(
    () => tmuxArgv('a\nkill-server', ['list-sessions'], { HOME: home, PATH: process.env.PATH }),
    /недопустимые символы/,
  );
});

test('tmuxArgv: вызывающий передаёт свой -S/-L — throw (В1)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-tmux');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, TMUX_BIN: stub };
  assert.throws(() => tmuxArgv('workerA', ['-S', '/tmp/evil.sock'], env), /запрещено передавать -L\/-S/);
  assert.throws(() => tmuxArgv('workerA', ['-L', 'evil'], env), /запрещено передавать -L\/-S/);
});

test('systemdRunArgv: без маркера — argv не тронут, бинарь дефолтный', () => {
  const home = fakeDir('pc-home-');
  assert.deepEqual(
    systemdRunArgv(['--unit=x', '/bin/true'], { HOME: home, PATH: process.env.PATH }),
    { bin: 'systemd-run', argv: ['--unit=x', '/bin/true'] },
  );
});

test('systemdRunArgv: под маркером — --setenv маркера ПЕРЕД argv вызывающего', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const canonRoot = execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim();
  assert.deepEqual(
    systemdRunArgv(['--unit=x', '/bin/true'], { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub }),
    { bin: stub, argv: ['--setenv', `CLAUDE_CONTROL_TEST_ROOT=${canonRoot}`, '--unit=x', '/bin/true'] },
  );
});

test('systemdRunArgv: вызывающий переопределяет маркер через --setenv — throw (В1)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(
    () => systemdRunArgv(['--setenv', 'CLAUDE_CONTROL_TEST_ROOT=/evil'], env),
    /запрещено переопределять/,
  );
});

test('systemdRunArgv: вызывающий передаёт -p/--property — throw целиком (В1)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(() => systemdRunArgv(['-p', 'Environment=FOO=bar'], env), /-p\/--property/);
});

test('systemdRunArgv: легитимный --setenv вызывающего (СВОЯ переменная) — не throw', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const canonRoot = execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim();
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.deepEqual(
    systemdRunArgv(['--setenv', 'MY_TASK_VAR=hello'], env),
    { bin: stub, argv: ['--setenv', `CLAUDE_CONTROL_TEST_ROOT=${canonRoot}`, '--setenv', 'MY_TASK_VAR=hello'] },
  );
});

// ---------------------------------------------------------------------------------------
// ДЕФЕКТ 2 (повторное ревью T2): голая форма `--setenv NAME` (БЕЗ "=value") у systemd-run
// НЕ ошибка выполнения — man: «When "=" and VALUE are omitted, the value of the variable is
// passed from the environment in which systemd-run is invoked» — тихий альтернативный канал
// присвоить маркерную переменную. Блок-паттерны выше требовали буквальный "=" в значении и
// голую форму пропускали. Репро ревьюера: `--setenv CLAUDE_CONTROL_TEST_ROOT --unit=x
// /bin/true` проходил с rc=0, argv нёс И наш `--setenv CLAUDE_CONTROL_TEST_ROOT=<root>`, И
// чужой голый `--setenv CLAUDE_CONTROL_TEST_ROOT` следом.
// ---------------------------------------------------------------------------------------

test('systemdRunArgv: голая форма --setenv CLAUDE_CONTROL_TEST_ROOT (раздельная, БЕЗ "=value") — throw (Дефект 2)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(
    () => systemdRunArgv(['--setenv', 'CLAUDE_CONTROL_TEST_ROOT', '--unit=x', '/bin/true'], env),
    /запрещено переопределять/,
  );
});

test('systemdRunArgv: голая форма -E CLAUDE_CONTROL_TEST_ROOT (раздельная, короткий флаг) — throw (Дефект 2)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(
    () => systemdRunArgv(['-E', 'CLAUDE_CONTROL_TEST_ROOT'], env),
    /запрещено переопределять/,
  );
});

test('systemdRunArgv: голая слитная форма --setenv=CLAUDE_CONTROL_TEST_ROOT (БЕЗ "=value") — throw (Дефект 2)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(
    () => systemdRunArgv(['--setenv=CLAUDE_CONTROL_TEST_ROOT'], env),
    /запрещено переопределять/,
  );
});

test('systemdRunArgv: голая слитная форма -ECLAUDE_CONTROL_TEST_ROOT (короткий флаг, БЕЗ "=value") — throw (Дефект 2)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(
    () => systemdRunArgv(['-ECLAUDE_CONTROL_TEST_ROOT'], env),
    /запрещено переопределять/,
  );
});

test('systemdRunArgv: голая форма --setenv для ЧУЖОЙ переменной — НЕ throw (не должен сломать T4)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const canonRoot = execFileSync('realpath', ['-e', root], { encoding: 'utf8' }).trim();
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.deepEqual(
    systemdRunArgv(['--setenv', 'MY_TASK_VAR'], env),
    { bin: stub, argv: ['--setenv', `CLAUDE_CONTROL_TEST_ROOT=${canonRoot}`, '--setenv', 'MY_TASK_VAR'] },
  );
});

test('systemdRunArgv: слитная форма -p<value> БЕЗ пробела (-pEnvironment=...) — throw целиком (Дефект 2, доп. находка parity)', () => {
  const home = fakeDir('pc-home-');
  const root = fakeDir('pc-root-');
  sentinelFile(root);
  const stub = join(root, 'fake-sdrun');
  makeFakeBin(stub);
  const env = { HOME: home, [MARKER_VAR]: root, DEPT_SYSTEMD_RUN: stub };
  assert.throws(() => systemdRunArgv(['-pEnvironment=FOO=bar'], env), /-p\/--property/);
});
