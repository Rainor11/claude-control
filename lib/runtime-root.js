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
  const prodDefault = path.join(home, '.claude-control');
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
      return nonEmpty(env.DEPT_HOME) || path.join(home, '.claude-control', 'department');
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

  const canonicalHome = realpathOrUndefined(home);
  if (canonicalHome !== undefined && canonicalRoot === canonicalHome) {
    fail(`${MARKER_VAR} не может совпадать с домашним каталогом (${canonicalHome}) — слишком широкий охват для тестового корня`);
  }

  const prodDefault = path.join(home, '.claude-control');
  const canonicalProdDefault = realpathOrUndefined(prodDefault);
  if (canonicalProdDefault !== undefined && canonicalRoot === canonicalProdDefault) {
    fail(`${MARKER_VAR} совпадает с боевым корнем (${prodDefault}) — тестам сюда нельзя, укажите отдельный временный каталог`);
  }

  const canonicalHardcodedProd = realpathOrUndefined(HARDCODED_PROD_CONTROL_DIR);
  if (canonicalHardcodedProd !== undefined && canonicalRoot === canonicalHardcodedProd) {
    fail(`${MARKER_VAR} совпадает с захардкоженным боевым корнем (${HARDCODED_PROD_CONTROL_DIR}) — тестам сюда нельзя`);
  }

  const sentinelPath = path.join(canonicalRoot, SENTINEL_NAME);
  if (!fs.existsSync(sentinelPath)) {
    fail(`${MARKER_VAR}='${canonicalRoot}' не содержит sentinel-файл '${SENTINEL_NAME}' — тестовый раннер обязан создать его перед использованием корня (защита от случайно указанного боевого/произвольного каталога)`);
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

  const marker = nonEmpty(e[MARKER_VAR]);
  if (marker !== undefined) {
    return resolveUnderTestMarker(profile, e, home, marker);
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
