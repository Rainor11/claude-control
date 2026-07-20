#!/usr/bin/env node
// lib/process-control.js — guard процесс-контроля (systemctl / systemd-run / tmux / запись
// systemd user unit-файлов) для node-компонентов claude-control (bin/dept-inbox,
// bin/dept-dispatcher). T2 изоляции тестов от боевого рантайма (см.
// .superpowers/sdd/iso-t2-brief.md) — зеркалит lib/process-control.sh, см. её шапку для
// полного описания четырёх проблем, которые guard закрывает (asana-project-integration.test.sh
// зовёт настоящий systemctl/tmux через claude-auto sleep; инцидент 20.07 — запись unit-шаблона
// в $HOME/.config/systemd/user ДО первого вызова systemctl; общее имя tmux-сокета;
// systemd-run не наследует env).
//
// ЭТА ЗАДАЧА ADDITIVE: guard пишется и тестируется, но НИ К ОДНОМУ файлу в bin/, bot/,
// channels/ НЕ подключается — подключение отдельная задача (T4).
//
// Переиспользует lib/runtime-root.js (resolveRuntimeRoot, contained, MARKER_VAR) — эта
// библиотека НЕ дублирует ни логику маркера, ни containment, только добавляет НОВЫЕ решения
// (какой каталог/сокет/--setenv использовать под маркером) поверх уже провалидированного
// test root.
'use strict';
const fs = require('fs');
const path = require('path');
const { resolveRuntimeRoot, contained, MARKER_VAR } = require('./runtime-root.js');

function fail(message) {
  throw new Error(`process-control: ${message}`);
}

// ---------------------------------------------------------------------------------------
// Слой A: резолв test root (делегирует ВСЮ валидацию resolveRuntimeRoot).
// ---------------------------------------------------------------------------------------

// resolveProcessControlTestRoot(env): null, если маркер не задан (прод-путь — ничего не
// проверяем, идентично сегодняшнему коду); канонический test root (string), если маркер
// задан и валиден; throw, если маркер задан, но невалиден (сообщение — из resolveRuntimeRoot,
// не дублируем текст здесь).
function resolveProcessControlTestRoot(env) {
  const e = env || process.env;
  if (!(MARKER_VAR in e)) return null;
  return resolveRuntimeRoot('control_only', e);
}

// ---------------------------------------------------------------------------------------
// Слой B: чистые функции решений (string/array → string/array, без обращения к файловой
// системе) — принимают уже резолвленный testRoot (null = "нет маркера"). Общие с bash-
// стороной кейсы — tests/fixtures/process-control-cases.json (конвенция репозитория:
// "чистые функции решений — в module.exports + unit-тест", см. dept-dispatcher.js
// runnerArgv/pickExecutable).
// ---------------------------------------------------------------------------------------

// unitDirDecision(testRootOrNull, home): каталог для systemd user unit-файлов. Буквальная
// конкатенация шаблонных строк (НЕ path.join) — паритет с bash `"$var/suffix"`-интерполяцией
// (см. В1 ревью T1: path.join нормализует "//"/".." там, где bash — нет; здесь новая логика,
// но паритет с bash-стороной ЭТОЙ библиотеки обязан быть побитовым для кросс-теста).
//
// В3 (ревью T2): bash-сторона читает HOME через `${HOME:-}` — не выставленная (или пустая)
// переменная даёт буквально ПУСТУЮ СТРОКУ, а не строку "undefined". `home` здесь может прийти
// как undefined/null (вызывающий не передал ключ HOME в env-объекте вовсе) — БЕЗ этой
// нормализации шаблонная строка дала бы буквальное "undefined/.config/systemd/user"
// (JS `${undefined}` → "undefined") там, где прод-путь без маркера обязан остаться
// побитово сегодняшним (`bin/claude-auto:53`).
function unitDirDecision(testRootOrNull, home) {
  const homeStr = home === undefined || home === null ? '' : home;
  if (testRootOrNull !== null && testRootOrNull !== undefined && testRootOrNull !== '') {
    return `${testRootOrNull}/systemd-user`;
  }
  return `${homeStr}/.config/systemd/user`;
}

// tmuxSocketArgv(name, testRootOrNull): без маркера — сегодняшнее `-L claude-<name>`
// (bin/claude-auto-run:81); под маркером — единый `-S "<root>/tmux.sock"` внутри test root.
function tmuxSocketArgv(name, testRootOrNull) {
  if (testRootOrNull !== null && testRootOrNull !== undefined && testRootOrNull !== '') {
    return ['-S', `${testRootOrNull}/tmux.sock`];
  }
  return ['-L', `claude-${name}`];
}

// systemdRunSetenvArgv(testRootOrNull): без маркера — пустой массив (argv не меняется,
// поведение идентично сегодняшнему); под маркером — ['--setenv', 'CLAUDE_CONTROL_TEST_ROOT=
// <root>'] — systemd-run не наследует env клиента, маркер обязан долететь до transient-юнита
// явно, иначе вложенный процесс потеряет защиту.
function systemdRunSetenvArgv(testRootOrNull) {
  if (testRootOrNull !== null && testRootOrNull !== undefined && testRootOrNull !== '') {
    return ['--setenv', `${MARKER_VAR}=${testRootOrNull}`];
  }
  return [];
}

// ---------------------------------------------------------------------------------------
// Слой C: резолв/проверки, трогающие файловую систему/PATH.
// ---------------------------------------------------------------------------------------

// resolveExecutablePath(name): аналог bash `command -v` — если name содержит разделитель
// пути, проверяет напрямую (абсолютный/относительный путь); иначе ищет по $PATH. Возвращает
// КАНОНИЧЕСКИЙ (realpath, симлинки разыменованы) путь или null, если не найден/не
// исполняемый. Разыменование симлинков важно: заглушка ВНУТРИ test root, будучи символической
// ссылкой на боевой бинарь СНАРУЖИ, обязана быть поймана containment-проверкой ниже — без
// realpath проверка увидела бы только путь самой ссылки, не её истинную цель.
function resolveExecutablePath(name) {
  const tryResolve = (candidate) => {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      // В4 (ревью T2): X_OK истинно и для КАТАЛОГА (нужен для обхода/traversal) — bash
      // `command -v` каталог НЕ принимает (проверено: `command -v /tmp` → rc=1), а голый
      // accessSync(X_OK) — принимал бы, подрывая смысл preflight (диспетчер получил бы
      // "бэкенд доступен" для шва, указывающего на каталог, и упал бы уже на самом exec).
      // fs.statSync СЛЕДУЕТ за симлинками (как и accessSync выше) — для симлинка на файл
      // isFile() истинно, для симлинка на каталог — ложно, паритет с bash сохраняется.
      if (!fs.statSync(candidate).isFile()) return null;
      return fs.realpathSync(candidate);
    } catch {
      return null;
    }
  };
  if (name.includes(path.sep)) {
    return tryResolve(name);
  }
  const pathEnv = process.env.PATH || '';
  for (const dir of pathEnv.split(path.delimiter)) {
    if (!dir) continue;
    const resolved = tryResolve(path.join(dir, name));
    if (resolved) return resolved;
  }
  return null;
}

// checkBinarySeam(varName, value, testRootOrNull): без testRoot — не проверяет ничего (прод-
// путь, идентичный сегодняшнему). С testRoot — value обязан резолвиться в исполняемый файл
// (resolveExecutablePath), и его канонический путь обязан лежать ВНУТРИ testRoot (contained
// из lib/runtime-root.js — переиспользуем, не дублируем containment).
function checkBinarySeam(varName, value, testRootOrNull) {
  if (testRootOrNull === null || testRootOrNull === undefined || testRootOrNull === '') return;
  const resolved = resolveExecutablePath(value);
  if (!resolved) {
    fail(`${varName}='${value}' не найден (PATH/абсолютный путь) — под тестовым маркером CLAUDE_CONTROL_TEST_ROOT обязана быть исполняемая заглушка внутри test root, а не невыставленный/битый шов`);
  }
  if (!contained(resolved, testRootOrNull)) {
    fail(`${varName}='${value}' (→ '${resolved}') указывает НЕ внутрь тестового корня '${testRootOrNull}' — под маркером обязана быть заглушка ВНУТРИ test root (иначе тест дотягивается до настоящего бинаря); либо ${varName} не переопределён вовсе (дефолт = реальный '${value}'), либо переопределён на путь/симлинк снаружи`);
  }
}

const BINARY_SEAM_DEFAULTS = Object.freeze({
  systemctl: ['SYSTEMCTL', 'systemctl'],
  systemd_run: ['DEPT_SYSTEMD_RUN', 'systemd-run'],
  tmux: ['TMUX_BIN', 'tmux'],
});

// preflight(cls, env): class ∈ systemctl | systemd_run | tmux | unit_dir. Явная функция
// проверки доступности бэкенда, ОТДЕЛЬНАЯ от реальных вызовов — будущий T4-вызывающий
// (dept-dispatcher.js) обязан вызвать её ДО мутации леджера (dept-ledger approval-exec
// --status executing идёт СТРОГО ДО systemd-run, bin/dept-dispatcher:454), чтобы отказ
// происходил ДО побочного эффекта. НЕ исполняет саму команду — только command-lookup +
// realpath (read-only).
function preflight(cls, env) {
  const e = env || process.env;
  const testRoot = resolveProcessControlTestRoot(e); // throw, если маркер невалиден
  if (cls === 'unit_dir') {
    unitDir(e); // резолв уже валиден по построению (testRoot либо null, либо провалидирован)
    return;
  }
  const spec = BINARY_SEAM_DEFAULTS[cls];
  if (!spec) {
    fail(`неизвестный класс '${cls}' (ожидался один из: systemctl, systemd_run, tmux, unit_dir)`);
  }
  const [varName, defaultBin] = spec;
  const raw = e[varName];
  const value = raw !== undefined && raw !== '' ? raw : defaultBin;
  checkBinarySeam(varName, value, testRoot);
}

// unitDir(env): резолвит каталог для systemd user unit-файлов (аналог bin/claude-auto
// SYSTEMD_USER_DIR="$HOME/.config/systemd/user", но marker-aware).
function unitDir(env) {
  const e = env || process.env;
  const testRoot = resolveProcessControlTestRoot(e);
  return unitDirDecision(testRoot, e.HOME);
}

// realpathM(p): JS-аналог `realpath -m` (К1 ревью T2) — канонизирует по СУЩЕСТВУЮЩЕМУ префиксу
// пути (разыменовывая ЕГО симлинки через fs.realpathSync), остаток (компоненты, которых ещё
// нет на диске — каталог обычно создаётся `mkdir -p` уже ПОСЛЕ этой проверки) приклеивает
// буквально, без обращения к файловой системе. `path.resolve` (было раньше) — чисто лексический
// резолв, симлинки НЕ разыменовывает вовсе: симлинк `<test_root>/unitlink` → каталог СНАРУЖИ
// test root лексически выглядит как "внутри" (путь начинается с test_root), хотя РЕАЛЬНО
// запись уйдёт наружу — containment-проверка на таком пути молча пропускала бы побег.
// Разыменование именно префикса (не всего пути целиком, как `fs.realpathSync` требовал бы
// полного существования) — то же самое, что делает GNU `realpath -m`: символические ссылки
// резолвятся, пока компоненты пути существуют, дальше (для ещё не созданных компонентов)
// путь просто дописывается литералом.
function realpathM(p) {
  let current = path.resolve(p);
  const suffix = [];
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const real = fs.realpathSync(current);
      return suffix.length ? path.join(real, ...suffix) : real;
    } catch {
      const parent = path.dirname(current);
      if (parent === current) {
        // Дошли до корня файловой системы, и даже он не резолвится — недостижимо на
        // нормальной ОС, но на всякий случай возвращаем лексический путь, а не зависаем.
        return path.resolve(p);
      }
      suffix.unshift(path.basename(current));
      current = parent;
    }
  }
}

// checkUnitDir(dir, env): валидатор ПРОИЗВОЛЬНОГО каталога unit-файлов (для кода, который
// продолжает вычислять каталог сам). Без маркера — не проверяет ничего. Под маркером — <dir>
// канонизируется через realpathM (К1 ревью T2: аналог bash `realpath -m`, разыменовывает
// симлинки СУЩЕСТВУЮЩЕГО префикса пути — каталог обычно ещё не существует целиком на момент
// проверки) и обязан быть ВНУТРИ test root.
function checkUnitDir(dir, env) {
  const e = env || process.env;
  const testRoot = resolveProcessControlTestRoot(e);
  if (testRoot === null) return;
  const canonDir = realpathM(dir);
  if (!contained(canonDir, testRoot)) {
    fail(`каталог unit-файлов '${dir}' (→ '${canonDir}') СНАРУЖИ тестового корня '${testRoot}' — под CLAUDE_CONTROL_TEST_ROOT запись unit-файлов вне test root запрещена (инцидент 20.07: тестовый прогон испортил боевой шаблон claude-auto@.service)`);
  }
}

// ---------------------------------------------------------------------------------------
// Слой D (В5 ревью T2): СБОРЩИКИ готового argv для будущего T4-вызывающего (dept-dispatcher.js/
// dept-inbox.js). НЕ exec-обёртки (сознательное решение T2, см. отчёт) — вызывающий сам решает
// execFile/execFileSync/таймауты; но на JS-стороне preflight был ЕДИНСТВЕННОЙ защитой:
// T4-код, собирающий argv руками, мог вызвать preflight() и потом ЗАБЫТЬ примешать
// systemdRunSetenvArgv/tmuxSocketArgv в реальный вызов — забыть маркер стало бы возможным.
// tmuxArgv/systemdRunArgv возвращают { bin, argv } уже с маркером внутри — забыть его в
// вызывающем коде физически негде, потому что сборка происходит здесь же, одним вызовом.
// ---------------------------------------------------------------------------------------

const WORKER_NAME_RE = /^[a-zA-Z0-9_-]+$/; // тот же charset, что bin/claude-auto:78/486/649

// argvHasFlag(argv, flagPrefixes): true, если хотя бы один элемент argv РАВЕН одному из
// flagPrefixes ИЛИ начинается с него (покрывает и раздельную форму `-L value`, и слитную
// `-Lvalue`/`--flag=value`).
function argvHasFlag(argv, flagPrefixes) {
  return argv.some((a) => flagPrefixes.some((p) => a === p || a.startsWith(p)));
}

// tmuxArgv(name, callerArgv, env): preflight('tmux') + резолв сокета (tmuxSocketArgv) +
// защита владения argv (В1 ревью T2) — возвращает { bin, argv } готовые для execFile у
// вызывающего. НЕ исполняет ничего сама.
function tmuxArgv(name, callerArgv, env) {
  const e = env || process.env;
  if (!WORKER_NAME_RE.test(name)) {
    fail(`tmuxArgv: имя воркера '${name}' содержит недопустимые символы (разрешено [a-zA-Z0-9_-])`);
  }
  // В1 (ревью T2): вызывающему запрещено передавать СВОЙ -L/-S — sock-флаг назначает ТОЛЬКО
  // guard. Повтор одноимённого флага в getopt-разборе — "последний побеждает" (для tmux `-S`
  // вдобавок ещё и молча гасит предыдущий `-L`, см. man tmux) — argv вызывающего идёт ПОСЛЕ
  // нашего, значит его -L/-S переопределил бы адресацию, которую guard обязан гарантировать.
  if (argvHasFlag(callerArgv, ['-L', '-S'])) {
    fail("tmuxArgv: вызывающему запрещено передавать -L/-S — сокет назначает guard, передайте только tmux-команду и её аргументы");
  }
  preflight('tmux', e);
  const testRoot = resolveProcessControlTestRoot(e);
  const raw = e.TMUX_BIN;
  const bin = raw !== undefined && raw !== '' ? raw : 'tmux';
  const sockArgs = tmuxSocketArgv(name, testRoot);
  return { bin, argv: [...sockArgs, ...callerArgv] };
}

// systemdRunArgv(callerArgv, env): preflight('systemd_run') + инъекция --setenv маркера
// (systemdRunSetenvArgv) + защита владения argv (В1 ревью T2) — возвращает { bin, argv }.
function systemdRunArgv(callerArgv, env) {
  const e = env || process.env;
  // В1 (ревью T2): та же угроза, что у tmux, но для env-инъекции. Два независимых вектора:
  //  1) --setenv/-E С ИМЕНЕМ НАШЕГО МАРКЕРА — systemd-run берёт последнее значение
  //     одноимённой переменной (man systemd-run: "--setenv может повторяться"), а наш
  //     --setenv стоит ПЕРВЫМ — чужой одноимённый после него победил бы. Другие --setenv
  //     (для СВОИХ переменных вызывающего) разрешены — это легитимный сценарий T4.
  //  2) -p/--property Environment=... — независимый способ присвоить env transient-юниту,
  //     которым НАШ КОД не пользуется вовсе — блокируем весь флаг целиком, не разбирая
  //     содержимое (проще и надёжнее, чем парсить произвольный список Environment=A=1 B=2).
  for (let i = 0; i < callerArgv.length; i += 1) {
    const a = callerArgv[i];
    if ((a === '--setenv' || a === '-E') && typeof callerArgv[i + 1] === 'string'
      && callerArgv[i + 1].startsWith(`${MARKER_VAR}=`)) {
      fail(`systemdRunArgv: вызывающему запрещено переопределять ${MARKER_VAR} через --setenv (маркер назначает guard)`);
    }
    if (/^(--setenv=|-E=?)/.test(a) && a.includes(`${MARKER_VAR}=`)) {
      fail(`systemdRunArgv: вызывающему запрещено переопределять ${MARKER_VAR} через --setenv (маркер назначает guard)`);
    }
    if (a === '-p' || a === '--property' || a.startsWith('--property=')) {
      fail('systemdRunArgv: вызывающему запрещено передавать -p/--property (Environment= — зарезервированный вектор для маркера, guard блокирует весь флаг)');
    }
  }
  preflight('systemd_run', e);
  const testRoot = resolveProcessControlTestRoot(e);
  const raw = e.DEPT_SYSTEMD_RUN;
  const bin = raw !== undefined && raw !== '' ? raw : 'systemd-run';
  const setenvArgs = systemdRunSetenvArgv(testRoot);
  return { bin, argv: [...setenvArgs, ...callerArgv] };
}

module.exports = {
  resolveProcessControlTestRoot,
  unitDirDecision,
  tmuxSocketArgv,
  systemdRunSetenvArgv,
  resolveExecutablePath,
  realpathM,
  checkBinarySeam,
  preflight,
  unitDir,
  checkUnitDir,
  tmuxArgv,
  systemdRunArgv,
  BINARY_SEAM_DEFAULTS,
};
