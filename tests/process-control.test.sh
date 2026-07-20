#!/bin/bash
# tests/process-control.test.sh — T2 (изоляция тестов от боевого рантайма, guard
# процесс-контроля). Bash-сторона lib/process-control.sh: см. .superpowers/sdd/iso-t2-brief.md
# для полного описания четырёх дыр, которые guard закрывает (asana-project-integration.test.sh
# зовёт настоящий systemctl/tmux; инцидент 20.07 — запись unit-шаблона в
# $HOME/.config/systemd/user; общее имя tmux-сокета; systemd-run не наследует env).
#
# ЗАПРЕЩЕНО: этот тест НЕ вызывает настоящие systemctl/systemd-run/tmux ни разу (включая
# read-only вроде is-active/list-units/show-environment) — только фейковые бинари во
# временных каталогах, созданные этим файлом.
#
# shellcheck disable=SC2030,SC2031  # НАМЕРЕННО: каждый сценарий ниже export'ит HOME/
# CLAUDE_CONTROL_TEST_ROOT/PATH/SYSTEMCTL/... ТОЛЬКО внутри своего `( ... )`-подшелла — цель
# именно в том, чтобы изменение НЕ протекло ни в родительский шелл, ни в соседний сценарий
# (иначе один прогон отравил бы env следующего). "Modification is local to subshell" — это
# не баг, а весь смысл изоляции; shellcheck не видит намерения, только факт локальности.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DIR/lib/process-control.sh"
FIXTURE="$DIR/tests/fixtures/process-control-cases.json"
fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq не найден — нужен для чтения tests/fixtures/process-control-cases.json"

# ---------------------------------------------------------------------------------------
# helper: гоняет чистую bash-функцию в ИЗОЛИРОВАННОМ подшелле (маркер/легаси-переменные не
# протекают между вызовами) и печатает stdout построчно.
# ---------------------------------------------------------------------------------------
run_pure() {
  local fn="$1"; shift
  (
    unset HOME CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
    export HOME="/nonexistent-home-not-used-by-pure-fns"
    # shellcheck disable=SC1090
    . "$LIB"
    "$fn" "$@"
  )
}

# ---------------------------------------------------------------------------------------
# Фикстура — чистые функции решений (unit_dir_decision / tmux_socket_argv /
# systemd_run_setenv_argv), общая с JS-стороной (tests/process-control.test.mjs делает
# кросс-проверку js-результата с bash-подпроцессом на ТЕХ ЖЕ входах) — не дублируем таблицу
# кейсов руками в обеих реализациях.
# ---------------------------------------------------------------------------------------

case_count="$(jq 'length' "$FIXTURE")"
i=0
while [ "$i" -lt "$case_count" ]; do
  name="$(jq -r ".[$i].name" "$FIXTURE")"
  fn="$(jq -r ".[$i].fn" "$FIXTURE")"
  case "$fn" in
    unit_dir_decision)
      test_root="$(jq -r ".[$i].args.testRoot" "$FIXTURE")"
      home="$(jq -r ".[$i].args.home" "$FIXTURE")"
      expect="$(jq -r ".[$i].expect" "$FIXTURE")"
      out="$(run_pure process_control_unit_dir_decision "$test_root" "$home")"
      [ "$out" = "$expect" ] || fail "fixture '$name': получили '$out', ожидали '$expect'"
      ;;
    tmux_socket_argv)
      name_arg="$(jq -r ".[$i].args.name" "$FIXTURE")"
      test_root="$(jq -r ".[$i].args.testRoot" "$FIXTURE")"
      expect_flag="$(jq -r ".[$i].expect[0]" "$FIXTURE")"
      expect_value="$(jq -r ".[$i].expect[1]" "$FIXTURE")"
      out="$(run_pure process_control_tmux_socket_argv "$name_arg" "$test_root")"
      out_flag="$(echo "$out" | sed -n '1p')"
      out_value="$(echo "$out" | sed -n '2p')"
      [ "$out_flag" = "$expect_flag" ] || fail "fixture '$name': флаг '$out_flag', ожидали '$expect_flag'"
      [ "$out_value" = "$expect_value" ] || fail "fixture '$name': значение '$out_value', ожидали '$expect_value'"
      ;;
    systemd_run_setenv_argv)
      test_root="$(jq -r ".[$i].args.testRoot" "$FIXTURE")"
      expect_len="$(jq -r ".[$i].expect | length" "$FIXTURE")"
      out="$(run_pure process_control_systemd_run_setenv_argv "$test_root")"
      if [ "$expect_len" -eq 0 ]; then
        [ -z "$out" ] || fail "fixture '$name': ожидали пустой argv, получили '$out'"
      else
        expect_flag="$(jq -r ".[$i].expect[0]" "$FIXTURE")"
        expect_value="$(jq -r ".[$i].expect[1]" "$FIXTURE")"
        out_flag="$(echo "$out" | sed -n '1p')"
        out_value="$(echo "$out" | sed -n '2p')"
        [ "$out_flag" = "$expect_flag" ] || fail "fixture '$name': флаг '$out_flag', ожидали '$expect_flag'"
        [ "$out_value" = "$expect_value" ] || fail "fixture '$name': значение '$out_value', ожидали '$expect_value'"
      fi
      ;;
    *)
      fail "fixture '$name': неизвестная fn '$fn'"
      ;;
  esac
  i=$((i + 1))
done
echo "OK: фикстура process-control-cases.json — $case_count кейсов (чистые функции решений)"

# ---------------------------------------------------------------------------------------
# Интеграционные тесты (маркер + файловая система) — по пунктам "Проверка" брифа iso-t2:
#  - без маркера: прокси на настоящий бинарь (фейковый бинарь в PATH, НЕ настоящий systemctl)
#  - под маркером без заглушки: отказ ДО побочного эффекта
#  - заглушка вне test root: отказ
#  - заглушка ВНУТРИ test root: успех, вызывается ИМЕННО заглушка
#  - каталог unit-файлов вне test root: отказ
#  - --setenv действительно несёт маркер
# ---------------------------------------------------------------------------------------

TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

make_fake_bin() {
  # make_fake_bin <path> <log_file> — создаёт исполняемый скрипт, который дописывает
  # "NAME <args>" (NAME = basename пути) в log_file и выходит с успехом.
  local p="$1" log="$2" bin_name
  bin_name="$(basename "$p")"
  cat > "$p" <<EOF
#!/bin/bash
echo "$bin_name \$*" >> "$log"
exit 0
EOF
  chmod +x "$p"
}

new_test_root() {
  local d; d="$(mktemp -d "$TMP_BASE/root-XXXXXX")"
  : > "$d/.claude-control-test-root"
  echo "$d"
}

# ---- без маркера: прокси на настоящий бинарь (проверяем фейковым бинарём в PATH) --------

fake_path_dir="$(mktemp -d "$TMP_BASE/fakepath-XXXXXX")"
fake_log="$(mktemp "$TMP_BASE/fakelog-XXXXXX")"
make_fake_bin "$fake_path_dir/systemctl" "$fake_log"
make_fake_bin "$fake_path_dir/tmux" "$fake_log"
make_fake_bin "$fake_path_dir/systemd-run" "$fake_log"

home_noop="$(mktemp -d "$TMP_BASE/home-XXXXXX")"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home_noop"
  export PATH="$fake_path_dir:$PATH"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemctl --user restart claude-auto@t.service
)" || fail "process_control_systemctl (без маркера) упал: $out"
command grep -q -- 'systemctl --user restart claude-auto@t.service' "$fake_log" \
  || fail "process_control_systemctl (без маркера) не вызвал фейковый systemctl из PATH: $(cat "$fake_log")"
: > "$fake_log"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home_noop"
  export PATH="$fake_path_dir:$PATH"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_tmux workerZ kill-session -t claude-workerZ
)" || fail "process_control_tmux (без маркера) упал: $out"
command grep -q -- 'tmux -L claude-workerZ kill-session -t claude-workerZ' "$fake_log" \
  || fail "process_control_tmux (без маркера) не вызвал фейковый tmux с -L claude-<name>: $(cat "$fake_log")"
: > "$fake_log"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home_noop"
  export PATH="$fake_path_dir:$PATH"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemd_run --user --collect --unit=dept-runner-x /bin/true --approval x
)" || fail "process_control_systemd_run (без маркера) упал: $out"
command grep -q -- 'systemd-run --user --collect --unit=dept-runner-x /bin/true --approval x' "$fake_log" \
  || fail "process_control_systemd_run (без маркера) не вызвал фейковый systemd-run без --setenv: $(cat "$fake_log")"
echo "$fake_log" | xargs cat | command grep -q -- '--setenv' \
  && fail "process_control_systemd_run (без маркера) добавил --setenv — argv обязан быть НЕ тронут без маркера"

echo "OK: без маркера — прокси на фейковый бинарь из PATH (systemctl/tmux/systemd-run), argv не тронут"

# ---- под маркером без заглушки: отказ ДО побочного эффекта ------------------------------

root1="$(new_test_root)"
home1="$(mktemp -d "$TMP_BASE/home-XXXXXX")"
: > "$fake_log"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export PATH="$fake_path_dir:$PATH"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_preflight systemctl 2>&1
  echo "rc=$?"
)"
echo "$out" | command grep -q "rc=1" || fail "preflight systemctl под маркером без заглушки обязан вернуть 1: $out"
echo "$out" | command grep -qi "заглушка\|не найден\|снаружи" || fail "preflight systemctl без заглушки: сообщение не объясняет причину: $out"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export PATH="$fake_path_dir:$PATH"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemctl --user restart claude-auto@t.service 2>&1
)" && fail "process_control_systemctl под маркером без заглушки обязан отказать: $out"
[ -s "$fake_log" ] && fail "process_control_systemctl под маркером без заглушки: побочный эффект произошёл (лог не пуст): $(cat "$fake_log")"

echo "OK: под маркером без заглушки — отказ ДО побочного эффекта (preflight + wrapper)"

# ---- заглушка вне test root: отказ -------------------------------------------------------

outside_bin_dir="$(mktemp -d "$TMP_BASE/outside-XXXXXX")"
outside_log="$(mktemp "$TMP_BASE/outsidelog-XXXXXX")"
make_fake_bin "$outside_bin_dir/fake-systemctl-outside" "$outside_log"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export SYSTEMCTL="$outside_bin_dir/fake-systemctl-outside"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemctl --user restart claude-auto@t.service 2>&1
)" && fail "заглушка SYSTEMCTL вне test root обязана отказывать: $out"
echo "$out" | command grep -qi "снаружи\|не внутрь" || fail "заглушка вне test root: сообщение не объясняет причину: $out"
[ -s "$outside_log" ] && fail "заглушка вне test root вызвана — побочный эффект произошёл: $(cat "$outside_log")"

echo "OK: заглушка SYSTEMCTL вне test root — отказ, без побочного эффекта"

# ---- заглушка-СИМЛИНК внутри test root на бинарь ВНЕ test root: отказ (defense-in-depth) --

symlink_stub="$root1/systemctl-symlink-to-outside"
ln -s "$outside_bin_dir/fake-systemctl-outside" "$symlink_stub"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export SYSTEMCTL="$symlink_stub"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemctl --user restart claude-auto@t.service 2>&1
)" && fail "заглушка-симлинк на бинарь снаружи test root обязана отказывать: $out"
echo "$out" | command grep -qi "снаружи\|не внутрь" || fail "заглушка-симлинк наружу: сообщение не объясняет причину: $out"

echo "OK: заглушка-симлинк ВНУТРИ test root, указывающая на бинарь СНАРУЖИ, — отказ"

# ---- заглушка ВНУТРИ test root: успех, вызывается именно заглушка -----------------------

stub_log="$(mktemp "$TMP_BASE/stublog-XXXXXX")"
make_fake_bin "$root1/fake-systemctl" "$stub_log"
make_fake_bin "$root1/fake-tmux" "$stub_log"
make_fake_bin "$root1/fake-systemd-run" "$stub_log"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export SYSTEMCTL="$root1/fake-systemctl"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemctl --user restart claude-auto@t.service
)" || fail "process_control_systemctl (заглушка внутри test root) упал: $out"
command grep -q -- 'fake-systemctl --user restart claude-auto@t.service' "$stub_log" \
  || fail "process_control_systemctl (заглушка внутри test root) не вызвал заглушку: $(cat "$stub_log")"

echo "OK: заглушка ВНУТРИ test root — успех, вызывается именно заглушка"

# ---- tmux под маркером: сокет -S "<root>/tmux.sock", а не -L claude-<name> --------------

: > "$stub_log"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL DEPT_SYSTEMD_RUN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export TMUX_BIN="$root1/fake-tmux"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_tmux workerQ kill-session -t claude-workerQ
)" || fail "process_control_tmux (заглушка внутри test root) упал: $out"
command grep -q -- "fake-tmux -S $root1/tmux.sock kill-session -t claude-workerQ" "$stub_log" \
  || fail "process_control_tmux под маркером не использовал единый сокет '<root>/tmux.sock': $(cat "$stub_log")"

echo "OK: tmux под маркером — единый сокет <root>/tmux.sock, не -L claude-<name>"

# ---- systemd-run под маркером: --setenv действительно несёт маркер ----------------------

: > "$stub_log"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  export DEPT_SYSTEMD_RUN="$root1/fake-systemd-run"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemd_run --user --collect --unit=dept-runner-x /bin/true --approval x
)" || fail "process_control_systemd_run (заглушка внутри test root) упал: $out"
command grep -q -- "--setenv CLAUDE_CONTROL_TEST_ROOT=$root1" "$stub_log" \
  || fail "process_control_systemd_run под маркером НЕ прокинул --setenv CLAUDE_CONTROL_TEST_ROOT: $(cat "$stub_log")"
command grep -q -- "fake-systemd-run --setenv CLAUDE_CONTROL_TEST_ROOT=$root1 --user --collect --unit=dept-runner-x /bin/true --approval x" "$stub_log" \
  || fail "process_control_systemd_run: --setenv должен идти ПЕРЕД аргументами вызывающего: $(cat "$stub_log")"

echo "OK: systemd-run под маркером — --setenv CLAUDE_CONTROL_TEST_ROOT=<root> реально прокинут"

# ---- unit_dir: без маркера — реальный $HOME/.config/systemd/user; под маркером — подкаталог test root --

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
  export HOME="$home_noop"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_unit_dir
)" || fail "process_control_unit_dir (без маркера) упал: $out"
[ "$out" = "$home_noop/.config/systemd/user" ] || fail "process_control_unit_dir (без маркера): получили '$out', ожидали '$home_noop/.config/systemd/user'"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_unit_dir
)" || fail "process_control_unit_dir (маркер) упал: $out"
[ "$out" = "$root1/systemd-user" ] || fail "process_control_unit_dir (маркер): получили '$out', ожидали '$root1/systemd-user'"

echo "OK: process_control_unit_dir — прод-каталог без маркера, подкаталог test root под маркером"

# ---- process_control_check_unit_dir: каталог вне test root — отказ; внутри — ок ----------

outside_dir="$(mktemp -d "$TMP_BASE/outside-unitdir-XXXXXX")"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_check_unit_dir "$outside_dir" 2>&1
)" && fail "process_control_check_unit_dir с каталогом вне test root обязан отказывать: $out"
echo "$out" | command grep -qi "снаружи" || fail "check_unit_dir вне test root: сообщение не объясняет причину: $out"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root1"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_check_unit_dir "$root1/some/nested/unit-dir"
)" || fail "process_control_check_unit_dir с каталогом внутри test root не должен отказывать: $out"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
  export HOME="$home_noop"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_check_unit_dir "/some/random/dir/without/marker"
)" || fail "process_control_check_unit_dir без маркера не должен проверять ничего: $out"

echo "OK: process_control_check_unit_dir — вне test root отказ, внутри и без маркера ок"

# ---- маркер невалиден (нет sentinel) — все функции отказывают, ни один бинарь не звался --

root_bad="$(mktemp -d "$TMP_BASE/root-bad-XXXXXX")"  # БЕЗ sentinel-файла
: > "$fake_log"
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root_bad"
  export PATH="$fake_path_dir:$PATH"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_systemctl --user restart claude-auto@t.service 2>&1
)" && fail "невалидный маркер (без sentinel) обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "невалидный маркер: сообщение resolve_runtime_root не долетело: $out"
[ -s "$fake_log" ] && fail "невалидный маркер: побочный эффект произошёл: $(cat "$fake_log")"

echo "OK: невалидный маркер (без sentinel) — отказ через делегирование resolve_runtime_root, без побочных эффектов"

# ---- то же самое для класса unit_dir (preflight + сама unit_dir) — отдельная ветка кода,
# не проходит через _process_control_check_binary_seam, поэтому проверяем явно.
out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root_bad"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_preflight unit_dir 2>&1
)" && fail "process_control_preflight unit_dir с невалидным маркером обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "preflight unit_dir невалидный маркер: сообщение не долетело: $out"

out="$(
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME
  export HOME="$home1" CLAUDE_CONTROL_TEST_ROOT="$root_bad"
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_unit_dir 2>&1
)" && fail "process_control_unit_dir с невалидным маркером обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "process_control_unit_dir невалидный маркер: сообщение не долетело: $out"

echo "OK: класс unit_dir — preflight и сама process_control_unit_dir тоже отказывают на невалидном маркере"

echo "PASS process-control"
