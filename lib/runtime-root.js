#!/usr/bin/env node
// lib/runtime-root.js — единственный резолвер корня рантайма (CONTROL_DIR/DEPT_HOME)
// для node-компонентов claude-control. До этого файла порядок приоритета переменных
// был скопирован построчно в 24 местах с ТРЕМЯ разными порядками (см.
// .superpowers/sdd/iso-t1-brief.md) — без общей точки правды тестовый прогон не имел
// механической границы от боевого флота (инцидент 20.07: прогон теста поднял посторонний
// systemd-юнит и оставил испорченную переменную в общем шаблоне claude-auto@.service).
//
// resolveRuntimeRoot() — ЕДИНСТВЕННОЕ место, где решение "отказать" под тестовым
// маркером CLAUDE_CONTROL_TEST_ROOT принимается. Fail-closed по умолчанию: любая
// двусмысленность (не резолвится, указывает на боевой каталог, легаси-переменная течёт
// наружу test root) — explicit throw с русским текстом, что произошло/что делать,
// НИКОГДА тихий фолбэк на боевой путь.
//
// Профили НЕ унифицированы (сознательно, см. бриф): CLAUDE_AUTO_HOME имеет конфликтующую
// семантику — bin/claude-auto-run:258 кладёт в неё каталог КОНКРЕТНОГО воркера
// (workers/<name>), а не корень флота. Дать ей единый глобальный приоритет означало бы,
// что команда из сессии воркера может принять workers/<name> за корень всего флота.
'use strict';
const fs = require('fs');
const path = require('path');

// Профили = буквальные сегодняшние строки в вызывающих файлах (сверено grep'ом на
// момент написания, не с таблицы брифа на слово — см. отчёт T1 про находку с dept-ledger).
const PROFILES = Object.freeze([
  'control_only',       // CONTROL_DIR="${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}" — 17 bash-файлов, напр. bin/claude-auto:49
  'auto_then_control',  // CONTROL_DIR="${CLAUDE_AUTO_HOME:-${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}}" — bin/dept-liveness-exec:24, bin/dept-liveness-request:33
  'auto_then_hardcoded', // const CC_HOME = process.env.CLAUDE_AUTO_HOME || '/home/rainor/.claude-control' — bin/claude-auto-liveness:14, bin/dept-inbox:16, bin/dept-rebase-check:16, bin/dept-dispatcher:153
  'dept_only',          // DEPT="${DEPT_HOME:-$HOME/.claude-control/department}" — bin/dept-mission-exec:20, bin/dept-exec-runner:28, bin/dept-spawn-exec:17
]);

const MARKER_VAR = 'CLAUDE_CONTROL_TEST_ROOT';
// Имя выбирает T3 (раннер, который его и создаёт) — здесь фиксируем контракт, чтобы
// резолвер и раннер не разъехались по имени файла.
const SENTINEL_NAME = '.claude-control-test-root';
// Литерал auto_then_hardcoded-профиля — ЖИВОЙ каталог на проде, буквально тот же текст,
// что хардкодят claude-auto-liveness/dept-inbox/dept-rebase-check/dept-dispatcher. НЕ
// $HOME-based специально: даже если резолвер вызван с чужим HOME, этот путь остаётся
// заблокирован под тестовым маркером (см. негативный кейс "маркер = боевой корень").
const HARDCODED_PROD_CONTROL_DIR = '/home/rainor/.claude-control';
// Легаси-переменные, утечка которых наружу test root — сигнал заражения тестового
// окружения боевым, независимо от того, какой ИМЕННО профиль сейчас резолвится (проверяем
// все три всегда — так проще не забыть, чем скоуп-фильтровать по профилю).
//
// Containment ПОД МАРКЕРОМ проверяется для всех трёх одинаково, включая CLAUDE_AUTO_HOME —
// несмотря на её конфликтующую worker-directory семантику (см. заголовок файла). Вопрос,
// не сломает ли это T5/T6 (worker-directory семантика CLAUDE_AUTO_HOME), закрыт ревью T1
// (см. .superpowers/sdd/iso-t1-report.md, поправка №3): `bin/claude-auto-run:35` вычисляет
// `home="$WORKERS_DIR/$name"`, где `WORKERS_DIR="$CONTROL_DIR/workers"` — каталог
// КОНКРЕТНОГО воркера ВСЕГДА подкаталог резолвленного корня, containment для него проходит
// по построению. T5 не обязан переоткрывать этот вопрос.
const LEGACY_VARS = Object.freeze(['CLAUDE_CONTROL_DIR', 'CLAUDE_AUTO_HOME', 'DEPT_HOME']);

function fail(message) {
  throw new Error(`runtime-root: ${message}`);
}

// bash `${VAR:-default}` считает пустую строку тем же, что "не задано" — резолвер обязан
// повторить это буквально для паритета, иначе CLAUDE_CONTROL_DIR="" вело бы себя иначе
// в новом коде, чем в старом.
function nonEmpty(value) {
  return value !== undefined && value !== null && value !== '' ? value : undefined;
}

// contained(child, root): true если child === root ИЛИ child начинается с root+separator.
// НЕ голый string prefix — иначе "/tmp/test-1-prod" прошёл бы как "подкаталог" "/tmp/test-1"
// (см. негативный тест в tests/runtime-root.test.mjs).
function contained(child, root) {
  return child === root || child.startsWith(root + path.sep);
}

// bashLiteralJoin(base, suffix): буквальная конкатенация как делает сегодняшний bash-код
// ("$HOME/.claude-control") — БЕЗ нормализации. path.join() схлопывает повторяющиеся "/" и
// лексически резолвит ".." — это ТОНЬШЕ, чем реальные bin/*-скрипты, которые просто
// интерполируют строку. Дифференциальный фазз (ревью T1, находка В1) нашёл 18 расхождений
// bash/js, все из-за того, что path.join() "нормализовал" там, где bash — нет (HOME с
// хвостовым слэшем, HOME="/", HOME с ".."). Паритет чинится здесь (не в bash), потому что
// bash уже буквально совпадает с сегодняшними строками в bin/* — это и есть источник
// истины, который резолвер обязан воспроизвести побитово.
function bashLiteralJoin(base, suffix) {
  return `${base}${suffix}`;
}

// rejectIfEntangledWithProd: боевой корень (prodPathRaw) и test root (canonicalRoot) не
// должны пересекаться НИ В ОДНОМ направлении — ни совпадать, ни быть вложенными друг в
// друга. Голая проверка на равенство (было изначально) пропускала два рабочих обхода
// fail-closed (ревью T1, находка К1): test root ВНУТРИ боевого дерева (например
// "$HOME/.claude-control/inner" — sentinel туда кладёт сам раннер, так что штатный вызов
// CLAUDE_CONTROL_TEST_ROOT=~/.claude-control/t проходил бы) и test root, СОДЕРЖАЩИЙ боевой
// корень целиком (например "/home", внутри которого лежит "/home/rainor/.claude-control").
function rejectIfEntangledWithProd(canonicalRoot, prodPathRaw) {
  const canonicalProd = realpathOrUndefined(prodPathRaw);
  if (canonicalProd === undefined) return; // боевой каталог не существует в этом окружении — сравнивать не с чем
  if (contained(canonicalRoot, canonicalProd) || contained(canonicalProd, canonicalRoot)) {
    fail(`${MARKER_VAR}='${canonicalRoot}' пересекается с боевым корнем (${prodPathRaw}) — совпадает с ним, вложен в него или содержит его целиком; тестам сюда нельзя, укажите отдельный временный каталог вне боевого дерева`);
  }
}

// realpathOrUndefined: для сравнения с боевыми путями, которые в тестовом окружении могут
// не существовать вовсе — тогда сравнение заведомо ложно (несуществующий путь не может
// совпасть с уже провалидированным существующим canonicalRoot), и we can safely skip it.
function realpathOrUndefined(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return undefined;
  }
}

function resolveLegacy(profile, env, home) {
  // bashLiteralJoin, НЕ path.join — паритет с буквальной bash-строкой "$HOME/.claude-control"
  // (см. комментарий у bashLiteralJoin выше, находка В1 ревью T1).
  const prodDefault = bashLiteralJoin(home, '/.claude-control');
  switch (profile) {
    case 'control_only':
      return nonEmpty(env.CLAUDE_CONTROL_DIR) || prodDefault;
    case 'auto_then_control':
      return nonEmpty(env.CLAUDE_AUTO_HOME) || nonEmpty(env.CLAUDE_CONTROL_DIR) || prodDefault;
    case 'auto_then_hardcoded':
      // CLAUDE_CONTROL_DIR здесь НЕ читается вовсе — реальный код (claude-auto-liveness и
      // соседи) его не знает. Это не упущение, а буквальное повторение сегодняшней строки.
      return nonEmpty(env.CLAUDE_AUTO_HOME) || HARDCODED_PROD_CONTROL_DIR;
    case 'dept_only':
      // DEPT_HOME с литеральным $HOME/.claude-control/department — реальный код (3 файла)
      // не консультирует ни CLAUDE_AUTO_HOME, ни CLAUDE_CONTROL_DIR для этого фоллбэка.
      return nonEmpty(env.DEPT_HOME) || bashLiteralJoin(home, '/.claude-control/department');
    default:
      /* недостижимо: profile уже провалидирован вызывающим resolveRuntimeRoot */
      return fail(`внутренняя ошибка: неизвестный профиль '${profile}' дошёл до resolveLegacy`);
  }
}

function resolveUnderTestMarker(profile, env, home, markerRaw) {
  if (!path.isAbsolute(markerRaw)) {
    fail(`${MARKER_VAR} должен быть абсолютным путём, получено '${markerRaw}'`);
  }

  let canonicalRoot;
  try {
    canonicalRoot = fs.realpathSync(markerRaw);
  } catch (e) {
    fail(`${MARKER_VAR}='${markerRaw}' не резолвится (каталог не существует или недоступен): ${e.message}`);
  }

  if (canonicalRoot === path.sep) {
    fail(`${MARKER_VAR} не может быть корнем файловой системы '${path.sep}'`);
  }

  // HOME обязан резолвиться — в отличие от prod-дефолтов ниже (которые в чистом
  // dev-окружении легитимно ещё не существуют), $HOME отсутствующим быть не должно;
  // если он всё же не резолвится, fail-closed: не можем поручиться, что test root с ним
  // не совпадает, значит не рискуем и отказываем, а не тихо пропускаем проверку.
  let canonicalHome;
  try {
    canonicalHome = fs.realpathSync(home);
  } catch (e) {
    fail(`HOME='${home}' не резолвится (${e.message}) — не могу проверить, что ${MARKER_VAR} не совпадает с домашним каталогом`);
  }
  if (canonicalRoot === canonicalHome) {
    fail(`${MARKER_VAR} не может совпадать с домашним каталогом (${canonicalHome}) — слишком широкий охват для тестового корня`);
  }

  // К1 (ревью T1): проверяем ОБЕ стороны вложенности для ОБОИХ боевых корней — не только
  // равенство. rejectIfEntangledWithProd сама делает realpath+containment в обе стороны.
  const prodDefault = bashLiteralJoin(home, '/.claude-control');
  rejectIfEntangledWithProd(canonicalRoot, prodDefault);
  rejectIfEntangledWithProd(canonicalRoot, HARDCODED_PROD_CONTROL_DIR);

  // М1 (ревью T1): sentinel обязан быть ОБЫЧНЫМ ФАЙЛОМ, не каталогом — existsSync() считал
  // каталог с таким именем валидным sentinel, что превращало проверку в помеху из одной
  // строки (`mkdir` вместо `touch`). statSync(...).isFile() — не existsSync().
  const sentinelPath = path.join(canonicalRoot, SENTINEL_NAME);
  let sentinelIsFile = false;
  try {
    sentinelIsFile = fs.statSync(sentinelPath).isFile();
  } catch {
    sentinelIsFile = false;
  }
  if (!sentinelIsFile) {
    fail(`${MARKER_VAR}='${canonicalRoot}' не содержит sentinel-файл '${SENTINEL_NAME}' (обязан быть обычным файлом, не каталогом) — тестовый раннер обязан создать его перед использованием корня (защита от случайно указанного боевого/произвольного каталога)`);
  }

  // Легаси-переменные под маркером ИГНОРИРУЮТСЯ для вычисления значения (маркер —
  // единственный корень), но если они заданы и указывают НАРУЖУ test root — это похоже на
  // утечку боевого окружения в тест, отказываем явно, а не молча переопределяем их.
  for (const name of LEGACY_VARS) {
    const raw = nonEmpty(env[name]);
    if (raw === undefined) continue;
    let canonicalLegacy;
    try {
      canonicalLegacy = fs.realpathSync(raw);
    } catch (e) {
      fail(`переменная ${name}='${raw}' задана вместе с ${MARKER_VAR}, но не резолвится (${e.message}) — уберите ${name} или укажите путь внутри тестового корня`);
    }
    if (!contained(canonicalLegacy, canonicalRoot)) {
      fail(`переменная ${name}='${raw}' задана вместе с ${MARKER_VAR}, но указывает НЕ внутрь тестового корня '${canonicalRoot}' — похоже на утечку боевого окружения в тест. Уберите ${name} или укажите путь внутри тестового корня.`);
    }
  }

  return profile === 'dept_only' ? path.join(canonicalRoot, 'department') : canonicalRoot;
}

// resolveRuntimeRoot(profile, env=process.env) -> string корня (CONTROL_DIR-подобное
// значение для control_only/auto_then_control/auto_then_hardcoded, DEPT_HOME-подобное для
// dept_only) либо throw Error с русским текстом причины отказа.
function resolveRuntimeRoot(profile, env) {
  const e = env || process.env;
  if (!PROFILES.includes(profile)) {
    fail(`неизвестный профиль '${profile}' (ожидался один из: ${PROFILES.join(', ')})`);
  }
  const home = e.HOME;
  if (!home) {
    fail('переменная HOME не установлена — резолвер не может вычислить боевой корень по умолчанию');
  }

  // В3 (ревью T1): "задана" проверяем через `in`, НЕ через nonEmpty()/`${:-}`-семантику.
  // Легаси-переменным ${VAR:-default} обязаны повторять "пустая строка = не задано" ради
  // паритета со старым bash-кодом — но MARKER_VAR НОВАЯ переменная без такого обязательства.
  // Реалистичный сценарий: раннер пишет CLAUDE_CONTROL_TEST_ROOT="$SOME_VAR", переменная не
  // выставлена — получаем "" и ОБЯЗАНЫ отказать (не абсолютный путь), а не тихо уйти в
  // боевой резолв. Раньше `nonEmpty("")` давал undefined → маркер считался "не задан" →
  // ровно тот тихий фолбэк на боевой путь, который файл обещает никогда не делать.
  if (MARKER_VAR in e) {
    return resolveUnderTestMarker(profile, e, home, e[MARKER_VAR]);
  }
  return resolveLegacy(profile, e, home);
}

module.exports = {
  resolveRuntimeRoot,
  PROFILES,
  MARKER_VAR,
  SENTINEL_NAME,
  HARDCODED_PROD_CONTROL_DIR,
};
