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
// М1 (Codex-аудит, финальное ревью изоляции T1-T7): строка ниже устарела — T4 ПОДКЛЮЧИЛ этот
// guard к `bin/dept-inbox` (systemctl is-active) и `bin/dept-dispatcher` (маркер в --setenv +
// preflight до пометки заявки executing), см. .superpowers/sdd/iso-t4-report.md. Bash-сторона
// (lib/process-control.sh) подключена тем же T4 к `bin/claude-auto-reconciler`,
// `bin/claude-auto`, `bin/claude-auto-run`. Инвариант "без маркера — побитово прежнее
// поведение" подтверждён отдельно для каждой точки — но формулировка "НИ К ОДНОМУ файлу...
// НЕ подключается" ниже больше не описывает реальность, оставлена как исторический контекст
// T2 (когда guard был только написан и протестирован, ещё не подключён нигде).
//
// ЭТА ЗАДАЧА (T2) БЫЛА ADDITIVE: guard писался и тестировался, но НИ К ОДНОМУ файлу в bin/,
// bot/, channels/ НЕ подключался — подключение было отдельной задачей (T4, см. выше — уже
// сделано).
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

// checkBinarySeam(varName, value, testRootOrNull): без testRoot (testRootOrNull === null,
// единственное, что легитимно означает "маркер не задан" — см. resolveProcessControlTestRoot)
// — не проверяет ничего (прод-путь, идентичный сегодняшнему). С testRoot — value обязан
// резолвиться в исполняемый файл (resolveExecutablePath), и его канонический путь обязан
// лежать ВНУТРИ testRoot (contained из lib/runtime-root.js — переиспользуем, не дублируем
// containment).
//
// В6 (Codex-аудит, финальное ревью изоляции T1-T7) — ЛОВУШКА АРНОСТИ: третий параметр
// раньше принимал `undefined` (аргумент просто НЕ ПЕРЕДАН) с ТЕМ ЖЕ fail-open поведением,
// что и легитимный `null` ("маркер не задан"). Bash-сторона (`process_control_check_binary_seam`
// в lib/process-control.sh) — ДВУХАРГУМЕНТНАЯ, сама резолвит test_root внутри себя; JS-сторона
// требует ТРЕТИЙ аргумент от вызывающего. Следующий мигрант (T4-код, портирующий bash-паттерн
// на JS "по аналогии") мог вызвать `checkBinarySeam(varName, value)` БЕЗ третьего аргумента —
// получил бы МОЛЧАЛИВЫЙ пропуск проверки ПОД МАРКЕРОМ, ровно тот класс дыры, который guard
// существует, чтобы закрыть. Теперь `undefined` — явный отказ (программная ошибка
// вызывающего), не "маркер не задан"; единственный сегодняшний вызывающий (`preflight` ниже)
// всегда передаёт результат `resolveProcessControlTestRoot()` (null либо непустая строка,
// НИКОГДА undefined), поведение для него не меняется.
function checkBinarySeam(varName, value, testRootOrNull) {
  if (testRootOrNull === undefined) {
    fail(`checkBinarySeam: третий аргумент testRootOrNull не передан (ожидался null — "маркер не задан", либо резолвленный test root) — вызов с недостачей аргумента мог бы молча пропустить проверку под маркером (В6, ловушка арности); это явный отказ, не тихий fail-open`);
  }
  if (testRootOrNull === null || testRootOrNull === '') return;
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

// realpathM(p): JS-аналог `realpath -m` (К1 ревью T2, доработан в повторном ревью T2 — см.
// ниже "ДЕФЕКТ 1", и снова доработан в финальном ревью изоляции T1-T7 — см. "ДЕФЕКТ 2").
// Разыменовывает символьные ссылки КОМПОНЕНТ-ЗА-КОМПОНЕНТОМ слева направо; компонент,
// которого нет на диске вовсе (ещё не создан — каталог обычно создаётся `mkdir -p` уже ПОСЛЕ
// этой проверки), приклеивается литералом БЕЗ дальнейших обращений к файловой системе — но
// обход компонентов ПРОДОЛЖАЕТСЯ (буквальные "."/".." в хвосте всё ещё сворачиваются, это
// чистая арифметика пути, не требующая существования на диске — см. ДЕФЕКТ 2).
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
// цели (с оставшимся хвостом исходного пути), рекурсивно.
//
// ДЕФЕКТ 2 (Codex-аудит В5, финальное ревью изоляции T1-T7): та версия абсолютизировала вход
// через `path.resolve(p)` (и рекурсивный шаг — через `path.join`/`path.resolve` над целью
// симлинка) — а ЭТИ функции схлопывают ".." ЛЕКСИЧЕСКИ, ДО обхода по компонентам. Репро:
// test root "<root>", "<root>/link" — симлинк на "/tmp/esc" (СНАРУЖИ test root).
// `path.resolve("<root>/link/..")` сокращает "link/.." в пустоту ПРЯМО В СТРОКЕ, до того как
// код успевает узнать, что "link" — симлинк наружу: `checkUnitDir("<root>/link/../escape")`
// возвращал `<root>/escape` (выглядит ВНУТРИ test root → APPROVED), тогда как GNU
// `realpath -m` резолвит "link" ФИЗИЧЕСКИ ПЕРВЫМ (→ "/tmp/esc"), и ТОЛЬКО ПОТОМ применяет
// ".." к результату (→ "/tmp/escape", СНАРУЖИ test root) — сверено фактическим запуском
// бинаря (`realpath -m -- "<root>/link/../escape"` → `/tmp/escape`; `mkdir -p` по такому
// пути физически создал бы каталог СНАРУЖИ test root). Латентно на живом флоте (у
// `checkUnitDir` сегодня нет боевых вызывающих, только тесты — bin/claude-auto использует
// bash-сторону `process_control_check_unit_dir`, где та же проверка идёт через реальный
// `realpath -m`), но тот же класс дыры, что чинили в Дефекте 1, — вернулся другим путём.
//
// Фикс Дефекта 2: НИКАКОЙ лексической нормализации ДО обхода. Абсолютизация — буквальная
// конкатенация (`toRawAbsolute`, тот же приём, что `bashLiteralJoin` в lib/runtime-root.js —
// та же причина: bash `"$var/suffix"`-интерполяция не нормализует, наш код обязан повторить
// это буквально). Компоненты (включая буквальные "." и "..") идут в обход КАК ЕСТЬ:
// "." отбрасывается сразу (не влияет на путь, не требует существования на диске); ".."
// СВОРАЧИВАЕТ УЖЕ РАЗРЕШЁННЫЙ префикс (`path.dirname(current)`, физический путь, накопленный
// обходом ДО этой точки, а не сырую строку ДО резолва симлинков) — ровно так делает GNU
// `realpath -m`. Сверено фактическим запуском на батарее кейсов (симлинк+"..", несуществующий
// компонент+"..", ".." у корня ФС, относительная цель символьной ссылки+".." — результат
// СНАРУЖИ резолвленной цели, а не "current/../x", цепочка символьных ссылок до dangling-конца,
// двойной слэш, символьная ссылка-цикл ± ".." в хвосте) — 20+ кейсов, ноль расхождений с
// реальным бинарём.
//
// Защита от цикла (не изменилась Дефектом 2, только реализована иначе): symlinksFollowed
// считает ВСЕ разыменования по цепочке (не сбрасывается на каждый readlink) — при превышении
// REALPATH_M_MAX_SYMLINKS дальнейшие символьные ссылки просто НЕ разыменовываются (та же
// ветка, что "не символьная ссылка вовсе") — компонент приклеивается литералом, обход
// ПРОДОЛЖАЕТСЯ (не рекурсия), поэтому последующие "."/".." в хвосте всё ещё сворачиваются —
// сверено фактическим запуском `realpath -m` на цикле a→b→a ± хвост из "x/../y": GNU-бинарь
// тоже не виснет, не падает и выдаёт путь с применённым "..", ровно как эта реализация. Наш
// порог (40) — тот же, что у ELOOP в Linux (MAXSYMLINKS).
const REALPATH_M_MAX_SYMLINKS = 40;

// toRawAbsolute(p): абсолютизация БЕЗ нормализации (см. ДЕФЕКТ 2 выше) — буквальная
// конкатенация с cwd, никогда path.resolve/path.join (оба схлопывают ".." лексически).
function toRawAbsolute(p) {
  if (path.isAbsolute(p)) return p;
  const cwd = process.cwd();
  return cwd.endsWith(path.sep) ? cwd + p : cwd + path.sep + p;
}

// splitRawComponents(absPath, root): режет АБСОЛЮТНЫЙ путь на компоненты БЕЗ нормализации —
// фильтрует только пустые сегменты (двойной слэш) и буквальные "." (гарантированный no-op,
// не требует обращения к ФС). ".." СОЗНАТЕЛЬНО остаётся в списке — сворачивается позже,
// ВНУТРИ обхода (realpathMWalk), не здесь лексически.
function splitRawComponents(absPath, root) {
  return absPath.slice(root.length).split(path.sep).filter((seg) => seg !== '' && seg !== '.');
}

function realpathMWalk(parts, current, root, symlinksFollowed) {
  for (let i = 0; i < parts.length; i += 1) {
    const part = parts[i];
    if (part === '..') {
      // Сворачиваем УЖЕ РАЗРЕШЁННЫЙ физический префикс (см. ДЕФЕКТ 2) — не лексическую
      // историю ДО резолва символьных ссылок, а `current`, накопленный обходом до этой точки.
      current = current === root ? root : path.dirname(current);
      continue;
    }
    const candidate = current === root ? current + part : current + path.sep + part;
    let st;
    try {
      st = fs.lstatSync(candidate);
    } catch {
      // Компонента нет вовсе (или недоступна) — литеральный append, обход ПРОДОЛЖАЕТСЯ
      // (последующие "."/".." в хвосте всё ещё сворачиваются — GNU `realpath -m` делает то
      // же самое для ещё не созданных путей, кейс "root/doesnotexist/../foo" → "root/foo").
      current = candidate;
      continue;
    }
    if (!st.isSymbolicLink() || symlinksFollowed >= REALPATH_M_MAX_SYMLINKS) {
      // Не символьная ссылка, ЛИБО порог разыменований исчерпан (защита от цикла a→b→a, см.
      // комментарий над REALPATH_M_MAX_SYMLINKS) — в обоих случаях просто append литералом и
      // продолжаем ТОТ ЖЕ обход (не рекурсия), чтобы последующие "."/".." в хвосте всё равно
      // сворачивались.
      current = candidate;
      continue;
    }
    const target = fs.readlinkSync(candidate);
    const targetAbs = path.isAbsolute(target) ? target : current + path.sep + target;
    const targetRoot = path.parse(targetAbs).root;
    const targetParts = splitRawComponents(targetAbs, targetRoot);
    // Резолв С НУЛЯ от цели симлинка (она сама может содержать ещё символьные ссылки/"..") +
    // ОСТАВШИЙСЯ хвост исходного пути (parts.slice(i + 1)) переносится КАК ЕСТЬ — хвостовые
    // ".." обязаны применяться к РЕЗОЛВЛЕННОЙ цели символьной ссылки, а не к `current` ДО
    // резолва (кейс "uplink/../x", где uplink → "../.." — результат СНАРУЖИ resolved(uplink),
    // сверено фактическим запуском `realpath -m`, см. комментарий над функцией).
    return realpathMWalk(targetParts.concat(parts.slice(i + 1)), targetRoot, targetRoot, symlinksFollowed + 1);
  }
  return current;
}

function realpathM(p) {
  // Б4 (bughunt, 21.07, паритет с bash-стороной): было — пустая/не-строка `p` тихо уходила в
  // toRawAbsolute("") = cwd + path.sep + "" (т.е. просто process.cwd()), и realpathM("")
  // молча резолвился в ТЕКУЩИЙ КАТАЛОГ, тогда как реальный GNU `realpath -m -- ""` завершается
  // ненулевым кодом ("No such file or directory", сверено фактическим запуском бинаря) — а
  // bash-сторона (lib/process-control.sh, process_control_check_unit_dir) пустой `dir`
  // явно отвергает ДО вызова realpath -m. Латентно на живом флоте (у checkUnitDir сегодня нет
  // боевых вызывающих, только тесты), но расхождение пары — явный throw, симметрично
  // bash-отказу, а не третья реализация семантики.
  if (typeof p !== 'string' || p === '') {
    fail(`realpathM: путь обязан быть непустой строкой, получено ${JSON.stringify(p)}`);
  }
  const rawAbsolute = toRawAbsolute(p);
  const root = path.parse(rawAbsolute).root;
  const parts = splitRawComponents(rawAbsolute, root);
  return realpathMWalk(parts, root, root, 0);
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
