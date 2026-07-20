#!/bin/bash
# tests/bootstrap.test.sh — тесты tests/lib/bootstrap.sh (T3, рубеж 2 из
# .superpowers/sdd/iso-t3-brief.md: "запустили тест в обход раннера — маркер
# отсутствует/невалиден/заглушки не на месте → явный отказ ДО тела теста").
#
# Этот файл — НОВЫЙ тест T3, значит сам обязан подключать bootstrap первой строкой (см.
# lint-bootstrap.test.sh) — запускать его напрямую (без tests/run) нельзя, он откажет так
# же, как и любой другой тест. Внутри, в ИЗОЛИРОВАННЫХ подшеллах, мы конструируем РАЗНЫЕ
# состояния песочницы и проверяем, что bootstrap.sh (source'ённый НАПРЯМУЮ, в обход раннера)
# ведёт себя как задокументировано — это тестирование БИБЛИОТЕКИ в подшеллах, а не повторный
# прямой запуск этого файла.
#
# shellcheck disable=SC2030,SC2031  # НАМЕРЕННО (тот же паттерн, что T2
# tests/process-control.test.sh): каждый сценарий ниже export'ит CLAUDE_CONTROL_TEST_ROOT/
# SYSTEMCTL/DEPT_SYSTEMD_RUN/TMUX_BIN ТОЛЬКО внутри своего `( ... )`/`$( ... )`-подшелла —
# цель именно в том, чтобы изменение НЕ протекло ни в родительский шелл, ни в соседний
# сценарий. Shellcheck не видит намерения, только факт локальности.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$DIR/tests/lib/bootstrap.sh"
fail() { echo "FAIL: $1"; exit 1; }

# Сверка литерала sentinel с T1 — не заводим свою копию имени, берём готовую переменную
# (bootstrap.sh уже source'ил lib/runtime-root.sh выше, _RUNTIME_ROOT_SENTINEL_NAME в scope).
SENTINEL="$_RUNTIME_ROOT_SENTINEL_NAME"
[ -n "$SENTINEL" ] || fail "_RUNTIME_ROOT_SENTINEL_NAME пуст после source bootstrap.sh — T1 не подключился?"

make_stub() {
  printf '#!/bin/bash\nexit 0\n' > "$1"
  chmod +x "$1"
}

# full_sandbox — полностью валидная песочница (sentinel + все 3 заглушки process-control).
full_sandbox() {
  local root; root="$(mktemp -d)"
  : > "$root/$SENTINEL"
  mkdir -p "$root/stubs"
  make_stub "$root/stubs/systemctl"
  make_stub "$root/stubs/systemd-run"
  make_stub "$root/stubs/tmux"
  realpath -e "$root"
}

# ---------------------------------------------------------------------------------------
# 1) маркер вообще не выставлен — прямой запуск теста в обход tests/run
# ---------------------------------------------------------------------------------------
out="$(
  unset CLAUDE_CONTROL_TEST_ROOT CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME \
        SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  # shellcheck disable=SC1090
  . "$BOOTSTRAP" 2>&1
  echo "UNREACHABLE"
)"
rc=$?
[ "$rc" -ne 0 ] || fail "без маркера bootstrap обязан отказать (получен rc=0): $out"
echo "$out" | command grep -q "UNREACHABLE" && fail "тело теста ПОСЛЕ bootstrap выполнилось несмотря на отказ: $out"
echo "$out" | command grep -q "CLAUDE_CONTROL_TEST_ROOT" || fail "без маркера: сообщение не называет CLAUDE_CONTROL_TEST_ROOT: $out"
echo "$out" | command grep -q "tests/run" || fail "без маркера: сообщение не подсказывает запустить через tests/run: $out"
echo "OK: без маркера — явный отказ, тело теста не выполнилось"

# ---------------------------------------------------------------------------------------
# 2) маркер выставлен, но НЕВАЛИДЕН (нет sentinel) — делегировано T1 resolve_runtime_root
# ---------------------------------------------------------------------------------------
root2="$(mktemp -d)"   # НЕТ sentinel-файла
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export CLAUDE_CONTROL_TEST_ROOT="$root2"
  # shellcheck disable=SC1090
  . "$BOOTSTRAP" 2>&1
  echo "UNREACHABLE"
)"
rc=$?
rm -rf "$root2"
[ "$rc" -ne 0 ] || fail "маркер без sentinel обязан отказать: $out"
echo "$out" | command grep -qi "sentinel" || fail "маркер без sentinel: сообщение не упоминает sentinel: $out"
echo "$out" | command grep -q "UNREACHABLE" && fail "тело теста выполнилось несмотря на отказ (нет sentinel): $out"
echo "OK: маркер без sentinel — явный отказ (делегировано T1)"

# ---------------------------------------------------------------------------------------
# 3) валидный test root (sentinel есть), НО ни одна заглушка process-control не подставлена
#    — SYSTEMCTL резолвится в настоящий системный бинарь СНАРУЖИ test root (T2 fail-closed).
#    Читаем ТОЛЬКО существование пути (command -v/realpath, без исполнения) — тот же
#    read-only preflight, что использует lib/process-control.sh, настоящий systemctl не
#    вызывается ни разу.
# ---------------------------------------------------------------------------------------
root3="$(mktemp -d)"; : > "$root3/$SENTINEL"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export CLAUDE_CONTROL_TEST_ROOT="$root3"
  # shellcheck disable=SC1090
  . "$BOOTSTRAP" 2>&1
  echo "UNREACHABLE"
)"
rc=$?
rm -rf "$root3"
[ "$rc" -ne 0 ] || fail "валидный test root БЕЗ заглушек обязан отказать: $out"
echo "$out" | command grep -q "systemctl" || fail "без заглушек: сообщение не называет класс systemctl (первый в порядке проверки): $out"
echo "$out" | command grep -q "UNREACHABLE" && fail "тело теста выполнилось несмотря на отказ (нет заглушек): $out"
echo "OK: валидный маркер без заглушек — явный отказ (делегировано T2 preflight)"

# ---------------------------------------------------------------------------------------
# 4) частичные заглушки — SYSTEMCTL подставлен, DEPT_SYSTEMD_RUN/TMUX_BIN нет
# ---------------------------------------------------------------------------------------
root4="$(mktemp -d)"; : > "$root4/$SENTINEL"
mkdir -p "$root4/stubs"; make_stub "$root4/stubs/systemctl"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME DEPT_SYSTEMD_RUN TMUX_BIN
  export CLAUDE_CONTROL_TEST_ROOT="$root4"
  export SYSTEMCTL="$root4/stubs/systemctl"
  # shellcheck disable=SC1090
  . "$BOOTSTRAP" 2>&1
  echo "UNREACHABLE"
)"
rc=$?
rm -rf "$root4"
[ "$rc" -ne 0 ] || fail "частичные заглушки (только SYSTEMCTL) обязаны отказать: $out"
echo "$out" | command grep -q "systemd_run" || fail "частичные заглушки: сообщение не называет недостающий класс systemd_run: $out"
echo "OK: частичные заглушки — явный отказ на первом недостающем классе (systemd_run)"

# ---------------------------------------------------------------------------------------
# 5) счастливый путь — маркер + sentinel + все 3 заглушки внутри test root → bootstrap
#    пропускает, тело теста выполняется дальше.
# ---------------------------------------------------------------------------------------
root5="$(full_sandbox)"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export CLAUDE_CONTROL_TEST_ROOT="$root5"
  export SYSTEMCTL="$root5/stubs/systemctl"
  export DEPT_SYSTEMD_RUN="$root5/stubs/systemd-run"
  export TMUX_BIN="$root5/stubs/tmux"
  # shellcheck disable=SC1090
  . "$BOOTSTRAP" 2>&1
  echo "REACHED"
)"
rc=$?
rm -rf "$root5"
[ "$rc" -eq 0 ] || fail "полностью валидная песочница обязана пройти bootstrap (rc=$rc): $out"
echo "$out" | command grep -q "REACHED" || fail "полностью валидная песочница: тело теста после bootstrap не выполнилось: $out"
echo "OK: полностью валидная песочница — bootstrap пропускает, тело теста выполняется"

# ---------------------------------------------------------------------------------------
# 6) заглушка-симлинк на бинарь СНАРУЖИ test root — сквозная проверка, что делегирование в
#    T2 (process_control_preflight → checkBinarySeam) реально работает через bootstrap, а не
#    просто "функция существует". Ни разу не исполняем сам симлинк/цель — только резолв пути.
# ---------------------------------------------------------------------------------------
root6="$(mktemp -d)"; : > "$root6/$SENTINEL"
mkdir -p "$root6/stubs"
make_stub "$root6/stubs/systemd-run"; make_stub "$root6/stubs/tmux"
outside_dir="$(mktemp -d)"; make_stub "$outside_dir/real-like-systemctl"
ln -s "$outside_dir/real-like-systemctl" "$root6/stubs/systemctl"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export CLAUDE_CONTROL_TEST_ROOT="$root6"
  export SYSTEMCTL="$root6/stubs/systemctl"
  export DEPT_SYSTEMD_RUN="$root6/stubs/systemd-run"
  export TMUX_BIN="$root6/stubs/tmux"
  # shellcheck disable=SC1090
  . "$BOOTSTRAP" 2>&1
  echo "UNREACHABLE"
)"
rc=$?
rm -rf "$root6" "$outside_dir"
[ "$rc" -ne 0 ] || fail "заглушка-симлинк на бинарь СНАРУЖИ test root обязана отказать: $out"
echo "$out" | command grep -q "systemctl" || fail "симлинк-побег: сообщение не называет класс systemctl: $out"
echo "OK: заглушка-симлинк наружу test root — явный отказ (делегировано T2)"

# ---------------------------------------------------------------------------------------
# 7) М1 (ревью T3) — запуск ПОД dash (не bash), минуя shebang: `sh tests/foo.test.sh`
#    интерпретирует ВЕСЬ файл (включая source bootstrap.sh) как POSIX sh — без детекта
#    строка BASH_SOURCE[0] упала бы под dash с невнятным "Bad substitution". Тело теста не
#    должно быть достижимо в любом случае (безопасность не страдает), но сообщение обязано
#    быть внятным, а не сырой ошибкой интерпретатора.
# ---------------------------------------------------------------------------------------
if command -v dash >/dev/null 2>&1; then
  out="$(
    unset CLAUDE_CONTROL_TEST_ROOT CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME \
          SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
    # shellcheck disable=SC2016  # НАМЕРЕННО одинарные кавычки: '$1' обязан резолвиться ВНУТРИ
    # -c скрипта dash (позиционный параметр ЕГО собственного вызова), не в этом bash — двойные
    # кавычки заставили бы РОДИТЕЛЬСКИЙ bash подставить $1 (пусто/чужое) ДО передачи в dash.
    dash -c '. "$1"; echo UNREACHABLE' -- "$BOOTSTRAP" 2>&1
  )"
  rc=$?
  [ "$rc" -ne 0 ] || fail "под dash bootstrap обязан отказать (получен rc=0): $out"
  echo "$out" | command grep -q "UNREACHABLE" && fail "тело теста ПОСЛЕ bootstrap выполнилось под dash: $out"
  echo "$out" | command grep -qi "Bad substitution" && fail "сообщение под dash — сырая ошибка интерпретатора, не внятный текст: $out"
  echo "$out" | command grep -qi "bash" || fail "под dash: сообщение не объясняет требование bash: $out"
  echo "OK: запуск под dash (не bash) — внятное сообщение, не сырая ошибка интерпретатора"
else
  echo "SKIP: dash не найден в PATH — сценарий М1 (не-bash интерпретатор) пропущен"
fi

echo "PASS bootstrap"
