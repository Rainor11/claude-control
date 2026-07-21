// tests/lib/sandbox.mjs — JS-эквивалент tests/lib/sandbox.sh: независимые тестовые корни
// внутри песочницы раннера (T6 изоляции, см. .superpowers/sdd/iso-t6-brief.md). Полное
// обоснование — в заголовке tests/lib/sandbox.sh (здесь не дублируется), коротко:
//
//   Резолвер T1 под маркером считает CLAUDE_CONTROL_TEST_ROOT ЕДИНСТВЕННЫМ источником корня —
//   `DEPT_HOME: mkdtempSync(tmpdir())` больше не даёт сценарию свой журнал (и законно
//   отвергается как «указывает наружу test root»). Тестам, у которых КАЖДЫЙ случай обязан
//   стартовать с чистого журнала (tests/dept-ledger.test.mjs — полсотни таких), нужен свой
//   ПОЛНОЦЕННЫЙ корень: sentinel + заглушки процесс-контроля ВНУТРИ него, всё внутри той же
//   песочницы раннера, которую раннер за собой убирает.
//
// Подключается ВТОРОЙ строкой, сразу после `import './lib/bootstrap.mjs';` (bootstrap обязан
// оставаться первым значимым действием файла — см. tests/lib/bootstrap-detect.sh).
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const require_ = createRequire(import.meta.url);
// Имя sentinel'а определяет T1 — берём оттуда, своё не выдумываем (тот же контракт, что у
// tests/run и tests/lib/sandbox.sh).
const { SENTINEL_NAME } = require_('../../lib/runtime-root.js');

// Три шва процесс-контроля (T2): переменная окружения → имя файла заглушки.
const SEAMS = [
  ['SYSTEMCTL', 'systemctl'],
  ['DEPT_SYSTEMD_RUN', 'systemd-run'],
  ['TMUX_BIN', 'tmux'],
];

// newTestRoot(prefix) → { root, dept, env }
//   root — абсолютный путь свежего подкорня внутри песочницы раннера (mkdtemp — имена не
//          сталкиваются, можно звать в цикле по одному на каждый тест-кейс);
//   dept — <root>/department, то, что вернёт резолвер для профиля dept_only (журнал отдела
//          лежит там же, где его увидит bin/dept-ledger);
//   env  — патч окружения для запуска боевой команды под ЭТИМ подкорнем. Легаси-переменные
//          гасятся (undefined в spread'е поверх process.env оставил бы старое значение —
//          поэтому execFileSync-обёртки обязаны раскладывать env через buildEnv ниже).
export function newTestRoot(prefix = 'root-') {
  const base = process.env.CLAUDE_CONTROL_TEST_ROOT;
  if (!base) {
    throw new Error('newTestRoot: CLAUDE_CONTROL_TEST_ROOT не выставлен — подкорень строится только внутри песочницы раннера (запусти тест через tests/run)');
  }
  const root = mkdtempSync(join(base, prefix));
  writeFileSync(join(root, SENTINEL_NAME), '');
  const dept = join(root, 'department');
  mkdirSync(dept, { recursive: true });

  const stubs = join(root, 'stubs');
  mkdirSync(stubs, { recursive: true });
  const env = { CLAUDE_CONTROL_TEST_ROOT: root };
  for (const [varName, binName] of SEAMS) {
    const src = process.env[varName];
    if (!src) {
      throw new Error(`newTestRoot: переменная шва ${varName} не выставлена — заглушки процесс-контроля подставляет раннер (запусти тест через tests/run)`);
    }
    const dst = join(stubs, binName);
    // КОПИЯ, не симлинк: T2 канонизирует шов через realpath перед containment-проверкой,
    // симлинк на заглушку раннера разыменовался бы наружу подкорня (см. sandbox.sh).
    copyFileSync(src, dst);
    chmodSync(dst, 0o755);
    env[varName] = dst;
  }
  return { root, dept, env };
}

// buildEnv(rootEnv, extra) — окружение для execFileSync: process.env + патч подкорня + extra,
// с ЯВНЫМ удалением легаси-переменных корня. Просто `{...process.env, ...env}` не годится:
// если внешний сценарий выставил DEPT_HOME, он остался бы в объекте и указывал бы наружу
// подкорня — резолвер T1 законно отказал бы («утечка боевого окружения в тест»).
export function buildEnv(rootEnv, extra = {}) {
  const env = { ...process.env, ...rootEnv, ...extra };
  for (const legacy of ['CLAUDE_CONTROL_DIR', 'CLAUDE_AUTO_HOME', 'DEPT_HOME']) {
    if (!(legacy in rootEnv) && !(legacy in extra)) delete env[legacy];
  }
  return env;
}
