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
function unitDirDecision(testRootOrNull, home) {
  if (testRootOrNull !== null && testRootOrNull !== undefined && testRootOrNull !== '') {
    return `${testRootOrNull}/systemd-user`;
  }
  return `${home}/.config/systemd/user`;
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

// checkUnitDir(dir, env): валидатор ПРОИЗВОЛЬНОГО каталога unit-файлов (для кода, который
// продолжает вычислять каталог сам). Без маркера — не проверяет ничего. Под маркером — <dir>
// (после лексического резолва, БЕЗ обращения к диску — path.resolve, аналог bash `realpath -m`:
// каталог обычно ещё не существует на момент проверки) обязан быть ВНУТРИ test root.
function checkUnitDir(dir, env) {
  const e = env || process.env;
  const testRoot = resolveProcessControlTestRoot(e);
  if (testRoot === null) return;
  const canonDir = path.resolve(dir);
  if (!contained(canonDir, testRoot)) {
    fail(`каталог unit-файлов '${dir}' (→ '${canonDir}') СНАРУЖИ тестового корня '${testRoot}' — под CLAUDE_CONTROL_TEST_ROOT запись unit-файлов вне test root запрещена (инцидент 20.07: тестовый прогон испортил боевой шаблон claude-auto@.service)`);
  }
}

module.exports = {
  resolveProcessControlTestRoot,
  unitDirDecision,
  tmuxSocketArgv,
  systemdRunSetenvArgv,
  resolveExecutablePath,
  checkBinarySeam,
  preflight,
  unitDir,
  checkUnitDir,
  BINARY_SEAM_DEFAULTS,
};
