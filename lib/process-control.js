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

// realpathM(p): JS-аналог `realpath -m` (К1 ревью T2, доработан в повторном ревью T2 —
// см. ниже "Дефект 1"). Разыменовывает симлинки КОМПОНЕНТ-ЗА-КОМПОНЕНТОМ слева направо;
// компонент, которого нет на диске вовсе (ещё не создан — каталог обычно создаётся
// `mkdir -p` уже ПОСЛЕ этой проверки), и весь остаток пути после него приклеиваются
// литералом, без дальнейших обращений к файловой системе.
//
// ДЕФЕКТ 1 (повторное ревью T2): первая версия строила растущий префикс `current` и звала
// `fs.realpathSync(current)` целиком — `realpathSync` кидает ENOENT И когда компонента
// просто нет, И когда компонент — СИМЛИНК С НЕСУЩЕСТВУЮЩЕЙ ЦЕЛЬЮ (dangling symlink). Оба
// случая ловились ОДНИМ catch-блоком и откатывались на "подняться к родителю, остаток
// дописать литералом" — то есть дальний конец битого симлинка НИКОГДА не резолвился, и
// containment-проверка (checkUnitDir) видела чисто лексический путь, который "выглядел"
// внутри test root, хотя симлинк реально вёл наружу. Репро: `ln -s /outside danglink`,
// `realpathM('danglink/foo/bar')` возвращал буквально `<root>/danglink/foo/bar` вместо
// `/outside/foo/bar`, которое даёт GNU `realpath -m` (сверено фактическим запуском бинаря).
//
// Фикс: различаем через `fs.lstatSync` (НЕ следует за симлинками, в отличие от statSync/
// realpathSync) — компонента нет вовсе (lstat кидает ENOENT) ПРОТИВ компонент существует И
// является симлинком (lstat успешен, isSymbolicLink() истинно) — тогда разыменовываем ЕГО
// через `fs.readlinkSync` явно, ДАЖЕ если цель не существует, и продолжаем резолв уже от
// цели (с оставшимся хвостом исходного пути), рекурсивно — ровно так же ведёт себя GNU
// `realpath -m` (сверено фактическим запуском: цепочка симлинков резолвится до последнего
// разрешимого звена, дальше — литерал).
//
// Защита от цикла: symlinksFollowed считает ВСЕ разыменования по цепочке (не сбрасывается
// на promise каждого readlink) — при превышении REALPATH_M_MAX_SYMLINKS резолв ОСТАНАВЛИВАЕТСЯ
// и остаток дописывается литералом, НЕ бросая ошибку и НЕ зацикливаясь. Это не гипотетическая
// защита: сверено фактическим запуском `realpath -m` на симлинк-цикле (a→b→a) — GNU-бинарь
// тоже не виснет и не падает, а возвращает путь БЕЗ дальнейшего резолва (rc=0). Наш порог
// (40) — тот же, что у ELOOP в Linux (MAXSYMLINKS).
const REALPATH_M_MAX_SYMLINKS = 40;

function realpathMWalk(absPath, symlinksFollowed) {
  const root = path.parse(absPath).root;
  const parts = absPath.slice(root.length).split(path.sep).filter(Boolean);
  let current = root;
  for (let i = 0; i < parts.length; i += 1) {
    const candidate = current === root ? current + parts[i] : current + path.sep + parts[i];
    let st;
    try {
      st = fs.lstatSync(candidate);
    } catch {
      // Компонента нет вовсе (или недоступна) — дальше резолвить нечего: остаток (текущий
      // компонент + всё, что после) дописываем литералом, как GNU `realpath -m` для ещё не
      // созданных компонентов.
      return parts.slice(i).reduce((acc, part) => acc + path.sep + part, current);
    }
    if (!st.isSymbolicLink()) {
      current = candidate;
      continue;
    }
    if (symlinksFollowed >= REALPATH_M_MAX_SYMLINKS) {
      // Цикл/чрезмерно длинная цепочка — не резолвим дальше, дописываем остаток литералом
      // (см. обоснование порога в комментарии над функцией).
      return parts.slice(i).reduce((acc, part) => acc + path.sep + part, current);
    }
    const target = fs.readlinkSync(candidate);
    const targetAbs = path.isAbsolute(target) ? target : path.join(current, target);
    const rest = parts.slice(i + 1);
    const newAbs = rest.length ? path.join(targetAbs, ...rest) : targetAbs;
    // Продолжаем резолв С НУЛЯ от цели симлинка (она сама может содержать ещё симлинки/"..")
    // + оставшийся хвост исходного пути — счётчик symlinksFollowed передаём дальше, не
    // сбрасываем, иначе цикл A→B→A никогда не наткнулся бы на порог.
    return realpathMWalk(path.resolve(newAbs), symlinksFollowed + 1);
  }
  return current;
}

function realpathM(p) {
  return realpathMWalk(path.resolve(p), 0);
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
  //
  // ДЕФЕКТ 2 (повторное ревью T2): голая форма `--setenv NAME` (без "=value") НЕ ошибка
  // выполнения у systemd-run — man: «When "=" and VALUE are omitted, the value of the
  // variable is passed from the environment in which systemd-run is invoked» — то есть это
  // ТИХИЙ альтернативный канал присвоить переменную transient-юниту. Все паттерны выше
  // требовали буквальный "=" в значении (`.startsWith(\`${MARKER_VAR}=\`)`,
  // `.includes(\`${MARKER_VAR}=\`)`) — голая форма имени БЕЗ "=" их не матчила и проходила
  // необнаруженной. Проверяем явно И раздельную форму (`--setenv`/`-E` + голое имя следующим
  // элементом), И слитную (`--setenv=NAME`, `-ENAME`, `-E=NAME`) без "=value".
  //
  // Слитные варианты сравниваются ТОЧНЫМ равенством/префиксом-с-"=" (не `.endsWith`/
  // `.includes` голого имени) — иначе постороннее ИМЯ, случайно заканчивающееся на
  // подстроку MARKER_VAR (например "-EFOO_CLAUDE_CONTROL_TEST_ROOT" для чужой переменной
  // "FOO_CLAUDE_CONTROL_TEST_ROOT"), ложноположительно блокировалось бы.
  const stuckBare = [`--setenv=${MARKER_VAR}`, `-E${MARKER_VAR}`, `-E=${MARKER_VAR}`];
  for (let i = 0; i < callerArgv.length; i += 1) {
    const a = callerArgv[i];
    const next = callerArgv[i + 1];
    if ((a === '--setenv' || a === '-E') && typeof next === 'string'
      && (next === MARKER_VAR || next.startsWith(`${MARKER_VAR}=`))) {
      fail(`systemdRunArgv: вызывающему запрещено переопределять ${MARKER_VAR} через --setenv (маркер назначает guard)`);
    }
    if (stuckBare.includes(a) || stuckBare.some((prefix) => a.startsWith(`${prefix}=`))) {
      fail(`systemdRunArgv: вызывающему запрещено переопределять ${MARKER_VAR} через --setenv (маркер назначает guard)`);
    }
    // Дефект 2 (доп. находка): bash-сторона блокирует -p/--property ЦЕЛИКОМ через wildcard
    // `-p*` (матчит и слитную форму `-pEnvironment=...` без пробела) — JS проверял только
    // точное `a === '-p'`, пропуская слитную форму. `a.startsWith('-p')` — паритет с bash.
    if (a.startsWith('-p') || a === '--property' || a.startsWith('--property=')) {
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
