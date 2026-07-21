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
# CLAUDE_CONTROL_TEST_ROOT/PATH/SYSTEMCTL/... ТОЛЬКО внутри своего `( ... )`-подшелла (через
# run_env — см. ниже) — цель именно в том, чтобы изменение НЕ протекло ни в родительский шелл,
# ни в соседний сценарий (иначе один прогон отравил бы env следующего). "Modification is local
# to subshell" — это не баг, а весь смысл изоляции; shellcheck не видит намерения, только факт
# локальности.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$DIR/lib/process-control.sh"

# T6. Раннер подставляет SYSTEMCTL/DEPT_SYSTEMD_RUN/TMUX_BIN (заглушки в песочнице) КАЖДОМУ
# тесту, подключившему пролог, — и это ровно то, чего ЭТОТ файл не хочет: он тестирует САМ
# guard, включая сценарии «переменная шва НЕ задана вовсе» (резолв голого имени через PATH
# без маркера; отказ под маркером, когда заглушки нет). Унаследованное значение подменило бы
# проверяемое поведение. Гасим их ОДИН раз здесь, ПОСЛЕ пролога (пролог сам их и требует —
# он проверяет, что раннер построил песочницу целиком): дальше каждый сценарий передаёт
# нужные значения СВОИМ env-префиксом на вызове, как и раньше. Внутри run_env/run_pure unset
# делать нельзя — там он затёр бы именно эти явные префиксы.
unset SYSTEMCTL DEPT_SYSTEMD_RUN TMUX_BIN
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
# М2 (ревью T2): run_env <root|-> <fn> [args...] — гоняет <fn> "$@" в изолированном подшелле:
# легаси-переменные (CLAUDE_CONTROL_DIR/CLAUDE_AUTO_HOME/DEPT_HOME) и CLAUDE_CONTROL_TEST_ROOT
# ГАРАНТИРОВАННО unset, затем маркер выставляется в "<root>" (если <root> != "-" — тогда
# маркер вообще не трогается, прод-путь без него). HOME/PATH/сид-переменные шва (SYSTEMCTL/
# TMUX_BIN/DEPT_SYSTEMD_RUN) вызывающий передаёт ЧЕРЕЗ env-префикс НА САМОМ ВЫЗОВЕ
# (`HOME="$h" SYSTEMCTL="$s" run_env "$root1" process_control_systemctl ...`) — bash
# экспортирует их ТОЛЬКО для этой команды (`run_env`), подшелл `( ... )` наследует их как
# обычное окружение процесса, экспорт НЕ протекает ни в родительский шелл, ни в соседний вызов
# (то же самое свойство изоляции, что было у ручных `( unset ...; export ...; ... )` — только
# без копипасты). Сворачивает паттерн, повторённый построчно 14+ раз.
#
# Два сценария ЭТОТ helper НЕ покрывает (оставлены как ручные `( ... )` с явным обоснованием
# в комментарии на месте): (1) когда HOME обязан быть буквально unset (не просто "какое-то
# значение"), (2) когда внутри подшелла нужно больше одной содержательной команды (например
# вызов + отдельный `echo "rc=$?"`).
run_env() {
  local root="$1" fn="$2"; shift 2
  (
    unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
    [ "$root" = "-" ] || export CLAUDE_CONTROL_TEST_ROOT="$root"
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

out="$(HOME="$home_noop" PATH="$fake_path_dir:$PATH" run_env - process_control_systemctl --user restart claude-auto@t.service)" \
  || fail "process_control_systemctl (без маркера) упал: $out"
command grep -q -- 'systemctl --user restart claude-auto@t.service' "$fake_log" \
  || fail "process_control_systemctl (без маркера) не вызвал фейковый systemctl из PATH: $(cat "$fake_log")"
: > "$fake_log"

out="$(HOME="$home_noop" PATH="$fake_path_dir:$PATH" run_env - process_control_tmux workerZ kill-session -t claude-workerZ)" \
  || fail "process_control_tmux (без маркера) упал: $out"
command grep -q -- 'tmux -L claude-workerZ kill-session -t claude-workerZ' "$fake_log" \
  || fail "process_control_tmux (без маркера) не вызвал фейковый tmux с -L claude-<name>: $(cat "$fake_log")"
: > "$fake_log"

out="$(HOME="$home_noop" PATH="$fake_path_dir:$PATH" run_env - process_control_systemd_run --user --collect --unit=dept-runner-x /bin/true --approval x)" \
  || fail "process_control_systemd_run (без маркера) упал: $out"
command grep -q -- 'systemd-run --user --collect --unit=dept-runner-x /bin/true --approval x' "$fake_log" \
  || fail "process_control_systemd_run (без маркера) не вызвал фейковый systemd-run без --setenv: $(cat "$fake_log")"
command grep -q -- '--setenv' "$fake_log" \
  && fail "process_control_systemd_run (без маркера) добавил --setenv — argv обязан быть НЕ тронут без маркера"

echo "OK: без маркера — прокси на фейковый бинарь из PATH (systemctl/tmux/systemd-run), argv не тронут"

# ---- под маркером без заглушки: отказ ДО побочного эффекта ------------------------------

root1="$(new_test_root)"
home1="$(mktemp -d "$TMP_BASE/home-XXXXXX")"
: > "$fake_log"

# Единственное место, где нужны ДВЕ содержательные команды в подшелле (вызов + echo rc) —
# run_env этого не покрывает (см. её комментарий), поэтому здесь — ручной subshell.
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

out="$(HOME="$home1" PATH="$fake_path_dir:$PATH" run_env "$root1" process_control_systemctl --user restart claude-auto@t.service 2>&1)" \
  && fail "process_control_systemctl под маркером без заглушки обязан отказать: $out"
[ -s "$fake_log" ] && fail "process_control_systemctl под маркером без заглушки: побочный эффект произошёл (лог не пуст): $(cat "$fake_log")"

echo "OK: под маркером без заглушки — отказ ДО побочного эффекта (preflight + wrapper)"

# ---- заглушка вне test root: отказ -------------------------------------------------------

outside_bin_dir="$(mktemp -d "$TMP_BASE/outside-XXXXXX")"
outside_log="$(mktemp "$TMP_BASE/outsidelog-XXXXXX")"
make_fake_bin "$outside_bin_dir/fake-systemctl-outside" "$outside_log"

out="$(HOME="$home1" SYSTEMCTL="$outside_bin_dir/fake-systemctl-outside" run_env "$root1" process_control_systemctl --user restart claude-auto@t.service 2>&1)" \
  && fail "заглушка SYSTEMCTL вне test root обязана отказывать: $out"
echo "$out" | command grep -qi "снаружи\|не внутрь" || fail "заглушка вне test root: сообщение не объясняет причину: $out"
[ -s "$outside_log" ] && fail "заглушка вне test root вызвана — побочный эффект произошёл: $(cat "$outside_log")"

echo "OK: заглушка SYSTEMCTL вне test root — отказ, без побочного эффекта"

# ---- заглушка-СИМЛИНК внутри test root на бинарь ВНЕ test root: отказ (defense-in-depth) --

symlink_stub="$root1/systemctl-symlink-to-outside"
ln -s "$outside_bin_dir/fake-systemctl-outside" "$symlink_stub"
out="$(HOME="$home1" SYSTEMCTL="$symlink_stub" run_env "$root1" process_control_systemctl --user restart claude-auto@t.service 2>&1)" \
  && fail "заглушка-симлинк на бинарь снаружи test root обязана отказывать: $out"
echo "$out" | command grep -qi "снаружи\|не внутрь" || fail "заглушка-симлинк наружу: сообщение не объясняет причину: $out"

echo "OK: заглушка-симлинк ВНУТРИ test root, указывающая на бинарь СНАРУЖИ, — отказ"

# ---- заглушка ВНУТРИ test root: успех, вызывается именно заглушка -----------------------

stub_log="$(mktemp "$TMP_BASE/stublog-XXXXXX")"
make_fake_bin "$root1/fake-systemctl" "$stub_log"
make_fake_bin "$root1/fake-tmux" "$stub_log"
make_fake_bin "$root1/fake-systemd-run" "$stub_log"

out="$(HOME="$home1" SYSTEMCTL="$root1/fake-systemctl" run_env "$root1" process_control_systemctl --user restart claude-auto@t.service)" \
  || fail "process_control_systemctl (заглушка внутри test root) упал: $out"
command grep -q -- 'fake-systemctl --user restart claude-auto@t.service' "$stub_log" \
  || fail "process_control_systemctl (заглушка внутри test root) не вызвал заглушку: $(cat "$stub_log")"

echo "OK: заглушка ВНУТРИ test root — успех, вызывается именно заглушка"

# ---- tmux под маркером: сокет -S "<root>/tmux.sock", а не -L claude-<name> --------------

: > "$stub_log"
out="$(HOME="$home1" TMUX_BIN="$root1/fake-tmux" run_env "$root1" process_control_tmux workerQ kill-session -t claude-workerQ)" \
  || fail "process_control_tmux (заглушка внутри test root) упал: $out"
command grep -q -- "fake-tmux -S $root1/tmux.sock kill-session -t claude-workerQ" "$stub_log" \
  || fail "process_control_tmux под маркером не использовал единый сокет '<root>/tmux.sock': $(cat "$stub_log")"

echo "OK: tmux под маркером — единый сокет <root>/tmux.sock, не -L claude-<name>"

# ---- systemd-run под маркером: --setenv действительно несёт маркер ----------------------

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run --user --collect --unit=dept-runner-x /bin/true --approval x)" \
  || fail "process_control_systemd_run (заглушка внутри test root) упал: $out"
command grep -q -- "--setenv CLAUDE_CONTROL_TEST_ROOT=$root1" "$stub_log" \
  || fail "process_control_systemd_run под маркером НЕ прокинул --setenv CLAUDE_CONTROL_TEST_ROOT: $(cat "$stub_log")"
command grep -q -- "fake-systemd-run --setenv CLAUDE_CONTROL_TEST_ROOT=$root1 --user --collect --unit=dept-runner-x /bin/true --approval x" "$stub_log" \
  || fail "process_control_systemd_run: --setenv должен идти ПЕРЕД аргументами вызывающего: $(cat "$stub_log")"

echo "OK: systemd-run под маркером — --setenv CLAUDE_CONTROL_TEST_ROOT=<root> реально прокинут"

# ---- unit_dir: без маркера — реальный $HOME/.config/systemd/user; под маркером — подкаталог test root --

out="$(HOME="$home_noop" run_env - process_control_unit_dir)" \
  || fail "process_control_unit_dir (без маркера) упал: $out"
[ "$out" = "$home_noop/.config/systemd/user" ] || fail "process_control_unit_dir (без маркера): получили '$out', ожидали '$home_noop/.config/systemd/user'"

out="$(HOME="$home1" run_env "$root1" process_control_unit_dir)" \
  || fail "process_control_unit_dir (маркер) упал: $out"
[ "$out" = "$root1/systemd-user" ] || fail "process_control_unit_dir (маркер): получили '$out', ожидали '$root1/systemd-user'"

echo "OK: process_control_unit_dir — прод-каталог без маркера, подкаталог test root под маркером"

# ---- process_control_check_unit_dir: каталог вне test root — отказ; внутри — ок ----------

outside_dir="$(mktemp -d "$TMP_BASE/outside-unitdir-XXXXXX")"
out="$(HOME="$home1" run_env "$root1" process_control_check_unit_dir "$outside_dir" 2>&1)" \
  && fail "process_control_check_unit_dir с каталогом вне test root обязан отказывать: $out"
echo "$out" | command grep -qi "снаружи" || fail "check_unit_dir вне test root: сообщение не объясняет причину: $out"

out="$(HOME="$home1" run_env "$root1" process_control_check_unit_dir "$root1/some/nested/unit-dir")" \
  || fail "process_control_check_unit_dir с каталогом внутри test root не должен отказывать: $out"

out="$(HOME="$home_noop" run_env - process_control_check_unit_dir "/some/random/dir/without/marker")" \
  || fail "process_control_check_unit_dir без маркера не должен проверять ничего: $out"

echo "OK: process_control_check_unit_dir — вне test root отказ, внутри и без маркера ок"

# ---- маркер невалиден (нет sentinel) — все функции отказывают, ни один бинарь не звался --

root_bad="$(mktemp -d "$TMP_BASE/root-bad-XXXXXX")"  # БЕЗ sentinel-файла
: > "$fake_log"
out="$(HOME="$home1" PATH="$fake_path_dir:$PATH" run_env "$root_bad" process_control_systemctl --user restart claude-auto@t.service 2>&1)" \
  && fail "невалидный маркер (без sentinel) обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "невалидный маркер: сообщение resolve_runtime_root не долетело: $out"
[ -s "$fake_log" ] && fail "невалидный маркер: побочный эффект произошёл: $(cat "$fake_log")"

echo "OK: невалидный маркер (без sentinel) — отказ через делегирование resolve_runtime_root, без побочных эффектов"

# ---- то же самое для класса unit_dir (preflight + сама unit_dir) — отдельная ветка кода,
# не проходит через process_control_check_binary_seam, поэтому проверяем явно.
out="$(HOME="$home1" run_env "$root_bad" process_control_preflight unit_dir 2>&1)" \
  && fail "process_control_preflight unit_dir с невалидным маркером обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "preflight unit_dir невалидный маркер: сообщение не долетело: $out"

out="$(HOME="$home1" run_env "$root_bad" process_control_unit_dir 2>&1)" \
  && fail "process_control_unit_dir с невалидным маркером обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "process_control_unit_dir невалидный маркер: сообщение не долетело: $out"

echo "OK: класс unit_dir — preflight и сама process_control_unit_dir тоже отказывают на невалидном маркере"

# ---------------------------------------------------------------------------------------
# В3 (ревью T2): process_control_unit_dir — HOME НЕ ПРОСТО пустой, а буквально НЕ ВЫСТАВЛЕН
# (unset), без маркера. Bash уже даёт `${HOME:-}` → буквально ПУСТУЮ строку → "/.config/
# systemd/user" (то же самое, что сегодняшняя литеральная интерполяция "$HOME/.config/..."
# в bin/claude-auto:53 при unset HOME без `set -u`) — этот тест ЛОЧИТ уже верное поведение;
# симметричный тест на JS-стороне (unitDir/unitDirDecision) реально нашёл и зафиксировал баг
# (шаблонная строка без HOME давала буквальное "undefined/.config/systemd/user").
#
# Ручной subshell (не run_env) — единственный сценарий, где HOME обязан быть буквально unset,
# а не "передан через env-префикс" (префикс всегда что-то ВЫСТАВЛЯЕТ).
# ---------------------------------------------------------------------------------------

out="$(
  unset HOME CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
  # shellcheck disable=SC1090
  . "$LIB"
  process_control_unit_dir
)" || fail "process_control_unit_dir (HOME unset, без маркера) упал: $out"
[ "$out" = "/.config/systemd/user" ] || fail "process_control_unit_dir (HOME unset): получили '$out', ожидали '/.config/systemd/user'"

echo "OK: process_control_unit_dir — HOME буквально unset (не просто пуст), без маркера — '/.config/systemd/user' (В3)"

# ---------------------------------------------------------------------------------------
# К1 (ревью T2): process_control_check_unit_dir — симлинк ВНУТРИ test root, указывающий на
# каталог СНАРУЖИ, обязан отказывать (не только буквальный путь заглушки, как в
# check_binary_seam выше, но и произвольный каталог unit-файлов). Bash уже использовал
# `realpath -m` (правильно с самого начала) — этот тест ЛОЧИТ поведение, а не чинит баг;
# симметричный тест на JS-стороне (checkUnitDir) реально нашёл и зафиксировал баг
# (path.resolve вместо аналога realpath -m, см. lib/process-control.js).
# ---------------------------------------------------------------------------------------

symlink_unitdir="$root1/unitlink-outside"
ln -sf "$outside_dir" "$symlink_unitdir"
out="$(HOME="$home1" run_env "$root1" process_control_check_unit_dir "$symlink_unitdir/nested/unit-dir" 2>&1)" \
  && fail "process_control_check_unit_dir с симлинком внутри test root, указывающим наружу, обязан отказывать: $out"
echo "$out" | command grep -qi "снаружи" || fail "check_unit_dir симлинк наружу: сообщение не объясняет причину: $out"

echo "OK: process_control_check_unit_dir — симлинк ВНУТРИ test root на каталог СНАРУЖИ — отказ (К1)"

# ---------------------------------------------------------------------------------------
# ДЕФЕКТ 1 (повторное ревью T2): process_control_check_unit_dir — БИТЫЙ (dangling) симлинк
# (цель не существует) обязан резолвиться через `realpath -m` ТОЧНО ТАК ЖЕ, как симлинк на
# существующий каталог (К1 выше). Bash-сторона зовёт настоящий `realpath -m` напрямую —
# GNU realpath уже резолвит битые симлинки корректно (сверено фактическим запуском бинаря),
# поэтому здесь дефекта НЕТ — эти тесты ЛОЧАТ уже верное поведение bash-стороны; симметричные
# тесты на JS-стороне (checkUnitDir/realpathM) реально нашли и зафиксировали баг (см.
# lib/process-control.js, "ДЕФЕКТ 1": fs.realpathSync не различал ENOENT компонента и
# ENOENT цели битого симлинка).
# ---------------------------------------------------------------------------------------

dangle_out="$root1/danglink-outside"
ln -sf "$outside_dir/never-created-xyz" "$dangle_out"   # цель НЕ существует, снаружи test root
out="$(HOME="$home1" run_env "$root1" process_control_check_unit_dir "$dangle_out/foo/bar" 2>&1)" \
  && fail "process_control_check_unit_dir с БИТЫМ симлинком наружу обязан отказывать: $out"
echo "$out" | command grep -qi "снаружи" || fail "check_unit_dir битый симлинк наружу: сообщение не объясняет причину: $out"

echo "OK: process_control_check_unit_dir — БИТЫЙ симлинк ВНУТРИ test root, указывающий НАРУЖУ (несуществующий путь), — отказ (Дефект 1)"

dangle_in="$root1/danglink-inside"
ln -sf "$root1/never-created-nested" "$dangle_in"   # цель НЕ существует, но ВНУТРИ test root
out="$(HOME="$home1" run_env "$root1" process_control_check_unit_dir "$dangle_in/foo/bar")" \
  || fail "process_control_check_unit_dir с БИТЫМ симлинком ВНУТРЬ (несуществующий путь) не должен отказывать: $out"

echo "OK: process_control_check_unit_dir — БИТЫЙ симлинк ВНУТРИ test root, указывающий ВНУТРЬ, — без ложного отказа (Дефект 1)"

chain2="$root1/chain2"
chain1="$root1/chain1"
ln -sf "$outside_dir/never-created-final-xyz" "$chain2"   # chain2 -> снаружи, битый
ln -sf "$chain2" "$chain1"                                 # chain1 -> chain2
out="$(HOME="$home1" run_env "$root1" process_control_check_unit_dir "$chain1/tail" 2>&1)" \
  && fail "process_control_check_unit_dir с цепочкой симлинков (последний битый, наружу) обязан отказывать: $out"
echo "$out" | command grep -qi "снаружи" || fail "check_unit_dir цепочка симлинков: сообщение не объясняет причину: $out"

echo "OK: process_control_check_unit_dir — цепочка симлинков с битым последним звеном наружу — отказ (Дефект 1)"

cyc_a="$root1/cyc_a"
cyc_b="$root1/cyc_b"
ln -sf "$cyc_b" "$cyc_a"
ln -sf "$cyc_a" "$cyc_b"
# Симлинк-цикл: GNU `realpath -m` не виснет и не падает (сверено фактическим запуском:
# `realpath -m` на a<->b цикле — rc=0, путь возвращается БЕЗ дальнейшего резолва). Оба звена
# цикла лежат ВНУТРИ test root, поэтому нерезолвленный (буквальный) путь тоже лексически
# внутри root — containment проходит, вызов обязан завершиться без отказа (и, что важнее,
# без зависания — если бы функция зациклилась, упал бы весь прогон по таймауту раннера).
# shellcheck disable=SC2016  # НАМЕРЕННО: $1/$2/$3/$4 внутри одинарных кавычек — позиционные
# параметры ВНУТРЕННЕГО `bash -c`, обязаны раскрыться ТАМ (после `unset`/`export` в его
# собственном окружении), а не здесь, в родительском шелле, до timeout/bash -c.
out="$(timeout 5 bash -c '
  unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
  export HOME="$1" CLAUDE_CONTROL_TEST_ROOT="$2"
  # shellcheck disable=SC1090
  . "$3"
  process_control_check_unit_dir "$4"
' bash "$home1" "$root1" "$LIB" "$cyc_a/tail" 2>&1)" \
  || fail "process_control_check_unit_dir с симлинк-циклом (оба звена внутри test root) не должен отказывать/висеть (rc=$?, timeout 5s): $out"

echo "OK: process_control_check_unit_dir — симлинк-цикл не виснет и не отказывает, когда цикл целиком внутри test root (Дефект 1)"

# ---------------------------------------------------------------------------------------
# К2 (ревью T2): process_control_tmux — имя воркера со встроенным переводом строки обязано
# быть отклонено ДО построения argv (было: построчный `read`-транспорт резал такое имя на
# ДВА argv-элемента, второй долетал до tmux как отдельный позиционный аргумент — argv-инъекция,
# проверено ревьюером на `$'a\nkill-server'`). Тест — БЕЗ маркера (проблема касалась ЛЮБОГО
# пути, не только под маркером) и явно проверяет, что фейковый бинарь НЕ был вызван вовсе.
# ---------------------------------------------------------------------------------------

: > "$fake_log"
bad_name=$'a\nkill-server'
out="$(HOME="$home_noop" PATH="$fake_path_dir:$PATH" run_env - process_control_tmux "$bad_name" kill-session 2>&1)" \
  && fail "process_control_tmux с именем, содержащим \\n, обязан отказывать: $out"
echo "$out" | command grep -qi "недопустимые символы" || fail "process_control_tmux: сообщение об отказе по имени не объясняет причину: $out"
[ -s "$fake_log" ] && fail "process_control_tmux с плохим именем: побочный эффект произошёл (лог не пуст): $(cat "$fake_log")"

echo "OK: process_control_tmux — имя со встроенным переводом строки отклонено ДО построения argv, без побочного эффекта (К2)"

# ---------------------------------------------------------------------------------------
# В1 (ревью T2): guard не должен позволять вызывающему подсовывать СВОЙ -L/-S (tmux) или
# переопределять/смузлить маркер через --setenv/-p (systemd-run) — иначе повтор одноимённого
# флага в getopt-разборе ("последний побеждает") отменяет адресацию/маркер, которую guard
# обязан гарантировать под test root.
# ---------------------------------------------------------------------------------------

: > "$stub_log"
out="$(HOME="$home1" TMUX_BIN="$root1/fake-tmux" run_env "$root1" process_control_tmux workerR -S /tmp/GLOBAL-prod.sock kill-session 2>&1)" \
  && fail "process_control_tmux с чужим -S от вызывающего обязан отказывать: $out"
echo "$out" | command grep -qi "не принимает -L/-S" || fail "process_control_tmux чужой -S: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_tmux с чужим -S: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_tmux — чужой -L/-S от вызывающего отклонён, без побочного эффекта (В1)"

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run --setenv CLAUDE_CONTROL_TEST_ROOT=/home/rainor/.claude-control --unit=x /bin/true 2>&1)" \
  && fail "process_control_systemd_run с чужим --setenv CLAUDE_CONTROL_TEST_ROOT обязан отказывать: $out"
echo "$out" | command grep -qi "запрещено переопределять" || fail "process_control_systemd_run чужой --setenv маркера: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_systemd_run с чужим --setenv маркера: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — чужой --setenv CLAUDE_CONTROL_TEST_ROOT отклонён, без побочного эффекта (В1)"

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run -p Environment=FOO=bar --unit=x /bin/true 2>&1)" \
  && fail "process_control_systemd_run с чужим -p Environment= обязан отказывать: $out"
echo "$out" | command grep -qi "не принимает -p/--property" || fail "process_control_systemd_run чужой -p: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_systemd_run с чужим -p: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — чужой -p/--property Environment= отклонён целиком, без побочного эффекта (В1)"

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run --setenv MY_TASK_VAR=hello --unit=x /bin/true)" \
  || fail "process_control_systemd_run с СВОИМ (не маркерным) --setenv не должен отказывать: $out"
command grep -q -- "--setenv CLAUDE_CONTROL_TEST_ROOT=$root1 --setenv MY_TASK_VAR=hello --unit=x /bin/true" "$stub_log" \
  || fail "process_control_systemd_run: легитимный --setenv вызывающего должен пройти ПОСЛЕ нашего маркерного: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — легитимный --setenv вызывающего (для СВОЕЙ переменной) не заблокирован (В1)"

# ---------------------------------------------------------------------------------------
# ДЕФЕКТ 2 (повторное ревью T2): голая форма `--setenv CLAUDE_CONTROL_TEST_ROOT` (БЕЗ
# "=value") — systemd-run в этом случае берёт значение переменной ИЗ ОКРУЖЕНИЯ САМОГО
# systemd-run (man: «When "=" and VALUE are omitted, the value of the variable is passed
# from the environment in which systemd-run is invoked»), а не падает с ошибкой. Все
# блок-паттерны выше требовали буквальный "=" — голая форма проходила необнаруженной.
# Репро ревьюера: `--setenv CLAUDE_CONTROL_TEST_ROOT --unit=x /bin/true` давал rc=0.
# ---------------------------------------------------------------------------------------

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run --setenv CLAUDE_CONTROL_TEST_ROOT --unit=x /bin/true 2>&1)" \
  && fail "process_control_systemd_run с голой формой --setenv CLAUDE_CONTROL_TEST_ROOT (без '=value') обязан отказывать: $out"
echo "$out" | command grep -qi "запрещено переопределять" || fail "process_control_systemd_run голая форма --setenv: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_systemd_run с голой формой --setenv маркера: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — голая форма --setenv CLAUDE_CONTROL_TEST_ROOT (раздельная) отклонена, без побочного эффекта (Дефект 2)"

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run -E CLAUDE_CONTROL_TEST_ROOT --unit=x /bin/true 2>&1)" \
  && fail "process_control_systemd_run с голой формой -E CLAUDE_CONTROL_TEST_ROOT обязан отказывать: $out"
echo "$out" | command grep -qi "запрещено переопределять" || fail "process_control_systemd_run голая форма -E: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_systemd_run с голой формой -E маркера: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — голая форма -E CLAUDE_CONTROL_TEST_ROOT (короткий флаг) отклонена, без побочного эффекта (Дефект 2)"

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run --setenv=CLAUDE_CONTROL_TEST_ROOT --unit=x /bin/true 2>&1)" \
  && fail "process_control_systemd_run с голой слитной формой --setenv=CLAUDE_CONTROL_TEST_ROOT обязан отказывать: $out"
echo "$out" | command grep -qi "запрещено переопределять" || fail "process_control_systemd_run голая слитная форма: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_systemd_run с голой слитной формой маркера: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — голая слитная форма --setenv=CLAUDE_CONTROL_TEST_ROOT отклонена, без побочного эффекта (Дефект 2)"

: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run --setenv MY_TASK_VAR --unit=x /bin/true)" \
  || fail "process_control_systemd_run с голой формой --setenv для ЧУЖОЙ переменной не должен отказывать (не должен сломать T4): $out"
command grep -q -- "--setenv CLAUDE_CONTROL_TEST_ROOT=$root1 --setenv MY_TASK_VAR --unit=x /bin/true" "$stub_log" \
  || fail "process_control_systemd_run: голая форма --setenv для чужой переменной должна пройти ПОСЛЕ нашего маркерного: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — голая форма --setenv для ЧУЖОЙ переменной не заблокирована (Дефект 2, без ложных срабатываний)"

# Дефект 2 (доп. находка, паритет): -p/--property уже блокируется bash-стороной ЦЕЛИКОМ через
# wildcard `-p*|--property*` — этот wildcard матчит и слитную форму `-pEnvironment=...` (без
# пробела) само по себе, дефекта здесь НЕТ (в отличие от JS-стороны, где было `a === '-p'`
# точное сравнение — см. lib/process-control.js). Тест ЛОЧИТ уже верное поведение.
: > "$stub_log"
out="$(HOME="$home1" DEPT_SYSTEMD_RUN="$root1/fake-systemd-run" run_env "$root1" process_control_systemd_run -pEnvironment=FOO=bar --unit=x /bin/true 2>&1)" \
  && fail "process_control_systemd_run со слитной формой -pEnvironment=... обязан отказывать: $out"
echo "$out" | command grep -qi "не принимает -p/--property" || fail "process_control_systemd_run слитная -p: сообщение не объясняет причину: $out"
[ -s "$stub_log" ] && fail "process_control_systemd_run со слитной формой -p: побочный эффект произошёл: $(cat "$stub_log")"

echo "OK: process_control_systemd_run — слитная форма -pEnvironment=... (без пробела) отклонена целиком (Дефект 2, паритет-lock)"

# ---------------------------------------------------------------------------------------
# В2 (ревью T2): shared class → (varName, defaultBin) фикстура — сверяет, что bash `case` в
# process_control_preflight действительно диспетчерит на VARNAME из фикстуры для КАЖДОГО
# бинарного класса (одна и та же фикстура кросс-проверяется JS-стороной на BINARY_SEAM_DEFAULTS
# в tests/process-control.test.mjs) — если завтра одна сторона переименует переменную для
# класса, а фикстуру не обновит, заглушка под ИМЕНЕМ ИЗ ФИКСТУРЫ перестанет находиться этой
# стороной, и тест упадёт, а не останется молча зелёным.
#
# Имя переменной (`seam_var`) здесь ДИНАМИЧЕСКОЕ (из фикстуры) — env-префикс требует
# статический идентификатор, поэтому единственная содержательная строка выше run_env — явный
# `export "$seam_var=..."` В ТОМ ЖЕ подшелле команд-подстановки (run_env создаёт СВОЙ
# внутренний подшелл, который наследует эту экспортированную переменную как обычно).
# ---------------------------------------------------------------------------------------

SEAM_FIXTURE="$DIR/tests/fixtures/process-control-binary-seam-classes.json"
seam_count="$(jq 'length' "$SEAM_FIXTURE")"
si=0
while [ "$si" -lt "$seam_count" ]; do
  seam_class="$(jq -r ".[$si].class" "$SEAM_FIXTURE")"
  seam_var="$(jq -r ".[$si].varName" "$SEAM_FIXTURE")"
  si=$((si + 1))

  seam_stub="$root1/fixture-seam-$seam_class"
  make_fake_bin "$seam_stub" "$stub_log"
  : > "$stub_log"

  out="$(
    export HOME="$home1" "$seam_var=$seam_stub"
    run_env "$root1" process_control_preflight "$seam_class"
  )" || fail "фикстура seam-классов '$seam_class': preflight с заглушкой под '$seam_var' обязан пройти (bash case мог разъехаться с varName из фикстуры): $out"
done

echo "OK: фикстура process-control-binary-seam-classes.json — bash preflight подхватывает заглушку под varName из фикстуры для всех $seam_count классов (В2)"

echo "PASS process-control"
