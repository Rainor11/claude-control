#!/bin/bash
# tests/lib/sandbox.sh — хелпер для тестов, которым по смыслу нужно НЕСКОЛЬКО НЕЗАВИСИМЫХ
# тестовых корней в одном прогоне (T6 изоляции тестов от боевого рантайма, см.
# .superpowers/sdd/iso-t6-brief.md). Подключается ВТОРОЙ строкой, СРАЗУ ПОСЛЕ bootstrap.sh
# (bootstrap обязан оставаться первым значимым действием файла — см. tests/lib/
# bootstrap-detect.sh):
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sandbox.sh"
#
# ЗАЧЕМ. Раннер (tests/run) даёт тесту ОДИН корень — CLAUDE_CONTROL_TEST_ROOT. Резолвер T1
# под маркером считает этот корень ЕДИНСТВЕННЫМ источником правды: DEPT_HOME/
# CLAUDE_CONTROL_DIR/CLAUDE_AUTO_HOME игнорируются для вычисления значения (и отвергаются,
# если указывают наружу корня). Значит легаси-приём «на каждый сценарий свой `mktemp -d`
# и DEPT_HOME=…» под границей больше не работает — ни как способ получить отдельный
# журнал, ни как способ изолировать сценарии друг от друга.
#
# Честный способ получить второй независимый корень — сделать ПОЛНОЦЕННЫЙ тестовый корень
# ВНУТРИ песочницы раннера (свой sentinel, свои заглушки процесс-контроля) и переключить на
# него маркер ТОЛЬКО для конкретного вызова. Граница при этом не ослабляется ни на грамм:
# подкорень лежит внутри той же песочницы в $TMPDIR, которую раннер убирает за собой; все
# проверки T1 (абсолютность, sentinel, непересечение с боевыми корнями) и T2 (заглушки
# ВНУТРИ актуального корня) проходят полностью, просто относительно подкорня.
#
# ЗАГЛУШКИ КОПИРУЮТСЯ, НЕ СИМЛИНКУЮТСЯ. process_control_check_binary_seam (T2) канонизирует
# шов через realpath ПЕРЕД containment-проверкой — симлинк на заглушку раннера
# (<песочница>/stubs/systemctl) разыменовался бы НАРУЖУ подкорня и получил бы законный отказ.
# Копия — обычный файл внутри подкорня, containment проходит.
#
# НЕ `set -u` здесь (source-able библиотека — тот же довод, что у lib/runtime-root.sh и
# tests/lib/bootstrap.sh: `set -u` в коде верхнего уровня протекает в шелл вызывающего).

# _RUNTIME_ROOT_SENTINEL_NAME — имя sentinel'а определяет T1, своё НЕ выдумываем. Обычно
# уже определено (bootstrap.sh подключил lib/runtime-root.sh), но source здесь идемпотентен
# и делает файл самодостаточным.
if [ -z "${_RUNTIME_ROOT_SENTINEL_NAME:-}" ]; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/runtime-root.sh"
fi

# new_test_root <имя-подкаталога> <имя-переменной-пути> <имя-массива-env>
#
# Создаёт подкорень <CLAUDE_CONTROL_TEST_ROOT>/<имя-подкаталога> (sentinel + копии заглушек
# процесс-контроля + пустой department/) и заполняет ДВЕ переменные вызывающего (nameref):
#   <имя-переменной-пути> — абсолютный путь подкорня;
#   <имя-массива-env>     — готовый префикс `env …` для запуска боевой команды ПОД ЭТИМ
#                           подкорнем: снимает легаси-переменные внешнего сценария (иначе
#                           они указывали бы наружу подкорня — законный отказ T1) и
#                           переставляет маркер + все три шва процесс-контроля.
#
# Использование:
#   new_test_root planerka PL_ROOT PL_ENV
#   "${PL_ENV[@]}" "$DIR/bin/dept-ledger" list --kind message
#   # журнал этого мира — "$PL_ROOT/department/events.jsonl"
new_test_root() {
  local _nts_name="${1:-}" _nts_path_var="${2:-}" _nts_env_var="${3:-}" _nts_dir _nts_stubs
  if [ -z "$_nts_name" ] || [ -z "$_nts_path_var" ] || [ -z "$_nts_env_var" ]; then
    echo "new_test_root: нужны три аргумента — <имя-подкаталога> <имя-переменной-пути> <имя-массива-env>" >&2
    return 1
  fi
  case "$_nts_name" in
    */*|.|..|"")
      echo "new_test_root: имя подкорня '$_nts_name' должно быть ОДНИМ сегментом без '/' (подкорень создаётся строго внутри песочницы раннера)" >&2
      return 1
      ;;
  esac
  if [ -z "${CLAUDE_CONTROL_TEST_ROOT:-}" ]; then
    echo "new_test_root: CLAUDE_CONTROL_TEST_ROOT не выставлен — подкорень строится только внутри песочницы раннера (запусти тест через tests/run)" >&2
    return 1
  fi

  _nts_dir="$CLAUDE_CONTROL_TEST_ROOT/$_nts_name"
  mkdir -p "$_nts_dir/department" || return 1
  : > "$_nts_dir/$_RUNTIME_ROOT_SENTINEL_NAME" || return 1

  # Копии заглушек процесс-контроля ВНУТРЬ подкорня (см. заголовок файла — почему копии,
  # а не симлинки). Источник — то, что подставил раннер; если шов не выставлен вовсе, тест
  # запущен не через раннер, и подкорень строить незачем.
  _nts_stubs="$_nts_dir/stubs"
  mkdir -p "$_nts_stubs" || return 1
  local _nts_var _nts_bin _nts_src
  for _nts_var in SYSTEMCTL:systemctl DEPT_SYSTEMD_RUN:systemd-run TMUX_BIN:tmux; do
    _nts_bin="${_nts_var#*:}"
    _nts_var="${_nts_var%%:*}"
    _nts_src="${!_nts_var:-}"
    if [ -z "$_nts_src" ]; then
      echo "new_test_root: переменная шва $_nts_var не выставлена — заглушки процесс-контроля подставляет раннер (запусти тест через tests/run)" >&2
      return 1
    fi
    cp -- "$_nts_src" "$_nts_stubs/$_nts_bin" || return 1
    chmod +x "$_nts_stubs/$_nts_bin" || return 1
  done

  declare -n _nts_path_ref="$_nts_path_var"
  declare -n _nts_env_ref="$_nts_env_var"
  _nts_path_ref="$_nts_dir"
  _nts_env_ref=(env -u CLAUDE_CONTROL_DIR -u CLAUDE_AUTO_HOME -u DEPT_HOME
    "CLAUDE_CONTROL_TEST_ROOT=$_nts_dir"
    "SYSTEMCTL=$_nts_stubs/systemctl"
    "DEPT_SYSTEMD_RUN=$_nts_stubs/systemd-run"
    "TMUX_BIN=$_nts_stubs/tmux")
}
