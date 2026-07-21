// tests/runtime-root.test.mjs — T1 (изоляция тестов от боевого рантайма). Резолвер
// заменяет 24 копии инлайновой логики CONTROL_DIR/DEPT_HOME с ТРЕМЯ разными порядками
// приоритета (см. .superpowers/sdd/iso-t1-brief.md) — без него тестовый прогон не имеет
// механической границы от боевого флота (см. инцидент 20.07: испорченная переменная
// окружения утекла в claude-auto@.service). resolveRuntimeRoot — единственное место,
// где решение "отказать" под тестовым маркером принимается: fail-closed по умолчанию.
// T6: обязательный пролог изоляции — первой значимой строкой файла. Фикстурные корни
// (в т.ч. заведомо враждебные) этот файл по-прежнему строит в tmpdir() СНАРУЖИ
// песочницы раннера — тот же довод, что в tests/runtime-root.test.sh: смешивать
// «корень под испытанием» с «корнем, который выдал раннер» нельзя.
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  mkdtempSync, symlinkSync, writeFileSync, readFileSync, realpathSync, mkdirSync, unlinkSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const { resolveRuntimeRoot, PROFILES, SENTINEL_NAME, HARDCODED_PROD_CONTROL_DIR } =
  createRequire(import.meta.url)('../lib/runtime-root.js');

const LIB_SH = fileURLToPath(new URL('../lib/runtime-root.sh', import.meta.url));
const FIXTURE_CASES = JSON.parse(
  readFileSync(fileURLToPath(new URL('./fixtures/runtime-root-cases.json', import.meta.url)), 'utf8'),
);

const fakeHome = () => mkdtempSync(join(tmpdir(), 'rr-home-'));
const fakeRoot = () => mkdtempSync(join(tmpdir(), 'rr-root-'));
const sentinel = (root) => writeFileSync(join(root, SENTINEL_NAME), '');

// resolveViaBash(profile, env): гоняет bash-реализацию (lib/runtime-root.sh) подпроцессом с
// ИЗОЛИРОВАННЫМ окружением (env option child_process ПОЛНОСТЬЮ заменяет environment, не
// мёржит) — только PATH (чтобы bash/realpath нашлись) + явно перечисленные переменные
// кейса. Используется кросс-реализационной проверкой ниже (В2 ревью T1).
function resolveViaBash(profile, env) {
  const childEnv = { PATH: process.env.PATH || '/usr/bin:/bin', ...env };
  try {
    const out = execFileSync(
      'bash',
      ['-c', 'set -u; . "$1"; resolve_runtime_root "$2"', 'bash', LIB_SH, profile],
      { env: childEnv, encoding: 'utf8' },
    );
    return { ok: true, value: out.replace(/\n$/, '') };
  } catch (e) {
    // М2 (Codex-аудит, финальное ревью изоляции T1-T7): trim трейлингового '\n' — bash `echo`
    // добавляет его, JS `Error.message` нет; без trim побайтовое сравнение jsResult.message
    // === bashResult.message ниже расходилось бы ВСЕГДА только из-за перевода строки, а не
    // из-за реального текста, что сделало бы assert бесполезным (либо вечно красным, либо
    // пришлось бы слабже — оба хуже явного trim здесь).
    return { ok: false, message: `${e.stdout || ''}${e.stderr || ''}`.replace(/\n$/, '') };
  }
}

// ---------------------------------------------------------------------------
// B2 (ревью T1, находка): таблица легаси-паритета (профиль + env + ожидание) больше НЕ
// дублируется руками параллельно в .mjs и .sh — общий tests/fixtures/runtime-root-cases.json
// гоняется ОБОИМИ раннерами (см. tests/runtime-root.test.sh), а здесь для каждого кейса ещё
// и дёргается bash-реализация подпроцессом и сравнивается С JS — именно этого не хватало,
// чтобы механически поймать В1 (bash/js разошлись на path.join-нормализации): раньше таблицы
// были независимыми копипастами и ни один тест не сравнивал bash-результат с js-результатом
// на одном и том же входе.
// ---------------------------------------------------------------------------

for (const c of FIXTURE_CASES) {
  test(`fixture-паритет: ${c.name}`, () => {
    let jsResult;
    try {
      jsResult = { ok: true, value: resolveRuntimeRoot(c.profile, c.env) };
    } catch (e) {
      jsResult = { ok: false, message: e.message };
    }
    const bashResult = resolveViaBash(c.profile, c.env);

    if (c.expect.ok) {
      assert.equal(jsResult.ok, true, `js обязан принять '${c.name}': ${jsResult.message}`);
      assert.equal(jsResult.value, c.expect.value, `js значение для '${c.name}'`);
      assert.equal(bashResult.ok, true, `bash обязан принять '${c.name}': ${bashResult.message}`);
      assert.equal(bashResult.value, c.expect.value, `bash значение для '${c.name}'`);
    } else {
      assert.equal(jsResult.ok, false, `js обязан отказать для '${c.name}'`);
      assert.match(jsResult.message, new RegExp(c.expect.errorPattern, 'i'));
      assert.equal(bashResult.ok, false, `bash обязан отказать для '${c.name}'`);
      assert.match(bashResult.message, new RegExp(c.expect.errorPattern, 'i'));
    }

    // Кросс-проверка bash/js МЕЖДУ СОБОЙ независимо от фикстуры — это и есть механическая
    // граница против В1-класса регрессий (расхождение поймается, даже если оба случайно
    // сойдутся на неверном с точки зрения фикстуры значении).
    assert.equal(jsResult.ok, bashResult.ok, `js/bash разошлись по accept/reject для '${c.name}'`);
    if (jsResult.ok) {
      assert.equal(jsResult.value, bashResult.value, `js/bash разошлись по значению для '${c.name}'`);
    } else {
      // М2 (Codex-аудит, финальное ревью изоляции T1-T7): раньше каждая сторона сверялась
      // ТОЛЬКО с общим c.expect.errorPattern (широкий regex по содержанию, например "HOME"),
      // а bash/js МЕЖДУ СОБОЙ по ТЕКСТУ сообщения не сверялись вовсе — префикс разъехался
      // (bash `resolve_runtime_root:`, js `runtime-root:`), 10/10 вердиктов и кодов совпадали,
      // и errorPattern эту разницу не ловил (он про содержание, не про первое слово). Явное
      // побайтовое сравнение текста — единственное, что закрывает именно этот класс
      // регрессии. Побочно проверено: после unификации префикса ОСТАЛЬНОЙ текст сообщений
      // (после префикса) у bash/js уже был идентичен для всех кейсов фикстуры — расхождение
      // было ИМЕННО в префиксе, не в содержании.
      assert.equal(jsResult.message, bashResult.message, `js/bash разошлись по ТЕКСТУ сообщения для '${c.name}'`);
    }
  });
}

test('все 4 профиля объявлены в PROFILES', () => {
  assert.deepEqual(
    [...PROFILES].sort(),
    ['auto_then_control', 'auto_then_hardcoded', 'control_only', 'dept_only'].sort(),
  );
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

test('маркер: пустая строка CLAUDE_CONTROL_TEST_ROOT="" ЗАДАНА (не unset) — обязан отказать, не тихо уйти в легаси (В3 ревью T1)', () => {
  // Раньше пустая строка трактовалась как "маркер не задан" → молчаливый фолбэк на боевой
  // резолв. Реалистичный сценарий: раннер пишет CLAUDE_CONTROL_TEST_ROOT="$SOME_VAR", а
  // переменная не выставлена — весь прогон уходил бы в боевой контур, выглядя нормальным.
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: '' }),
    /абсолютн/,
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

test('М1 (ревью T1): sentinel-КАТАЛОГ не принимается как валидный sentinel — нужен обычный файл', () => {
  const home = fakeHome();
  const root = fakeRoot();
  mkdirSync(join(root, SENTINEL_NAME)); // sentinel как ПОДКАТАЛОГ, не файл
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
  // auto_then_hardcoded-профиля, даже если HOME указывает на другое место. Только
  // fs.realpathSync (read-only stat), никакой записи/чтения содержимого.
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: HARDCODED_PROD_CONTROL_DIR }),
    /боев/,
  );
});

// ---------------------------------------------------------------------------
// К1 (ревью T1, КРИТИЧНОЕ): containment боевого корня — обе стороны вложенности, для
// обоих боевых корней. Голая equality-проверка пропускала test root ВНУТРИ боевого дерева
// (раннер сам кладёт туда sentinel — рабочий обход fail-closed) и test root, СОДЕРЖАЩИЙ
// боевой корень целиком.
// ---------------------------------------------------------------------------

test('К1: test root ВНУТРИ $HOME-боевого дерева ($HOME/.claude-control/inner) — отказ, а не accept', () => {
  const home = fakeHome();
  const prodDir = join(home, '.claude-control');
  mkdirSync(prodDir);
  const inner = join(prodDir, 'inner');
  mkdirSync(inner);
  sentinel(inner); // раннер сам кладёт sentinel — голая проверка это не поймает
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: inner }),
    /боев/,
  );
});

test('К1: symlink на test root ВНУТРИ $HOME-боевого дерева — отказ после разыменования', () => {
  const home = fakeHome();
  const prodDir = join(home, '.claude-control');
  mkdirSync(prodDir);
  const inner = join(prodDir, 'inner');
  mkdirSync(inner);
  sentinel(inner);
  const link = join(tmpdir(), `rr-link-inner-${process.pid}-${Date.now()}`);
  symlinkSync(inner, link);
  try {
    assert.throws(
      () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: link }),
      /боев/,
    );
  } finally {
    unlinkSync(link);
  }
});

test('К1: test root, СОДЕРЖАЩИЙ $HOME-боевой корень целиком (base — родитель $HOME/.claude-control) — отказ', () => {
  const base = fakeRoot();
  const home = join(base, 'home');
  mkdirSync(home);
  mkdirSync(join(home, '.claude-control'));
  // base != home (проверка равенства с HOME её не поймает), но base СОДЕРЖИТ prodDefault
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: base }),
    /боев/,
  );
});

test('К1: test root, СОДЕРЖАЩИЙ захардкоженный боевой корень (/home содержит /home/rainor/.claude-control) — отказ (read-only realpath)', () => {
  // /home — стандартная точка монтирования, гарантированно существует; никакой записи или
  // чтения содержимого /home/rainor/.claude-control, только fs.realpathSync (read-only stat).
  const home = fakeHome();
  assert.throws(
    () => resolveRuntimeRoot('control_only', { HOME: home, CLAUDE_CONTROL_TEST_ROOT: '/home' }),
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
