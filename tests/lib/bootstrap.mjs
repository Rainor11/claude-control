// tests/lib/bootstrap.mjs — обязательный пролог для tests/*.test.mjs (эквивалент
// tests/lib/bootstrap.sh для .mjs-тестов). T3 изоляции тестов от боевого рантайма, см.
// .superpowers/sdd/iso-t3-brief.md. `.mjs`-тесты запускают CLI подпроцессом (execFileSync/
// execFile — см. dept-dispatcher.test.mjs, dept-inbox.test.mjs) точно так же, как shell-тесты
// — значит способны дотянуться до боевого рантайма точно так же, и нуждаются в ТОМ ЖЕ
// рубеже 2 (см. tests/lib/bootstrap.sh — полное обоснование там, здесь не повторяется).
//
// Подключается ОДНОЙ строкой первым делом (побочный эффект самого импорта — модуль ничего
// не экспортирует, факта импорта достаточно, чтобы отказ произошёл ДО остального кода теста,
// включая любые top-level side-effect'ы вроде mkdtempSync):
//   import './lib/bootstrap.mjs';
//
// Контракт ТОТ ЖЕ, что у bash-стороны: этот модуль НИЧЕГО не готовит сам (sentinel/заглушки
// создаёт раннер) — только проверяет, переиспользуя lib/runtime-root.js (resolveRuntimeRoot)
// и lib/process-control.js (preflight). Ни логика маркера, ни containment, ни
// resolve-executable здесь не дублируются.
import { createRequire } from 'node:module';

const require_ = createRequire(import.meta.url);
// Путь относительно ЭТОГО файла (tests/lib/bootstrap.mjs) — ../../lib/... это корень репо.
const { resolveRuntimeRoot } = require_('../../lib/runtime-root.js');
const { preflight } = require_('../../lib/process-control.js');

function die(reason) {
  process.stderr.write(`tests/lib/bootstrap.mjs: ${reason}\n`);
  process.stderr.write('tests/lib/bootstrap.mjs: запусти тест через раннер, не напрямую: tests/run <имя файла>\n');
  process.exit(1);
}

// Рубеж 2, шаг 1: маркер вообще не выставлен — прямой запуск в обход tests/run. Проверяем
// членство ключа в process.env (паритет с bash `${VAR+set}` — T1 уже выбрал эту семантику
// для CLAUDE_CONTROL_TEST_ROOT, см. resolveRuntimeRoot про `MARKER_VAR in e`).
if (!('CLAUDE_CONTROL_TEST_ROOT' in process.env)) {
  die('маркер CLAUDE_CONTROL_TEST_ROOT не выставлен — тест запущен в обход tests/run, боевой контур ничем не защищён');
}

// Рубеж 2, шаг 2: маркер выставлен, но невалиден — resolveRuntimeRoot делает всю проверку
// (T1), здесь только оборачиваем throw через die().
try {
  resolveRuntimeRoot('control_only', process.env);
} catch (e) {
  die(e.message);
}

// Рубеж 2, шаг 3: заглушки процесс-контроля — раннер обязан подставить SYSTEMCTL/
// DEPT_SYSTEMD_RUN/TMUX_BIN внутри test root ДО запуска теста; без них preflight резолвит
// настоящий системный бинарь снаружи test root и сам откажет (T2 fail-closed) — здесь просто
// оборачиваем сообщение.
for (const cls of ['systemctl', 'systemd_run', 'tmux']) {
  try {
    preflight(cls, process.env);
  } catch (e) {
    die(`заглушка процесс-контроля класса '${cls}' не на месте (раннер обязан создать её внутри test root ДО запуска теста): ${e.message}`);
  }
}
